#!/bin/bash

################
# Invoked on startup by Docker
#
# Performs several actions:
#   - Ensures that the IIQ WAR, patches, and efixes are installed
#   - If we are running the 'single container' model, installs mysqld locally
#   - If the database is not initialized, initializes and patches it
#     - NOTE: This doesn't work for Oracle. You need to pre-initialize the Oracle DB.
#   - Installs the identityiq DB schema objects
#   - If the database already existed, stops when its version doesn't match this IIQ build
#   - Widens the description column on spt_configuration, spt_custom and spt_rule
#   - If there are no objects in IIQ, imports init.xml and init-lcm.xml
#     - NOTE: An import that reports an error exits non-zero, so the stack won't start.
#   - If there are any object XMLs in /opt/iiq/objects, imports them
#   - If there are any objects installed, just imports sp.init-custom.xml
#   - Installs any plugins in /opt/iiq/plugins
#   - Starts Tomcat, listening on port 8080

iiq() {
	COMMAND=$1
	echo "Executing iiq console command '$COMMAND'"
	IIQ_OUTPUT=$(mktemp)
	echo $COMMAND | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console 2>&1 | tee "${IIQ_OUTPUT}"

	# The console exits 0 even when an import fails. It prints the exception at the
	# start of a line (optionally after the "> " prompt), which log4j and stack trace
	# lines never do, so match on that and stop the container.
	if grep -qE '^(> )*[A-Za-z_][A-Za-z0-9_.$]*(Exception|Error)\b' "${IIQ_OUTPUT}"; then
		echo "=> FAILED: iiq console command '$COMMAND' reported an error:" >&2
		grep -E '^(> )*[A-Za-z_][A-Za-z0-9_.$]*(Exception|Error)\b' "${IIQ_OUTPUT}" >&2
		echo "=> Last objects processed before the failure:" >&2
		grep -E '^(> )*(Including File|[A-Za-z]+:)' "${IIQ_OUTPUT}" | tail -3 >&2
		rm -f "${IIQ_OUTPUT}"
		exit 1
	fi
	rm -f "${IIQ_OUTPUT}"
}

# SSBs often widen the description column on a few tables (Oracle allows it), and
# their objects won't import into the stock 1024-character column. Widen it here.
# Checks the current type first, so it's a no-op once done and also fixes databases
# created before this existed.
widenDescriptionColumns() {
	DB=$1
	for TABLE in spt_configuration spt_custom spt_rule; do
		if [[ "${DB}" == "mssql" ]]; then
			sqlcmd -C -N o -b -U "${MSSQL_SA_USER:-SA}" -P "${MSSQL_SA_PASSWORD}" -S "${MSSQL_HOST}" -d identityiq -Q \
				"IF (SELECT CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='identityiq' AND TABLE_NAME='${TABLE}' AND COLUMN_NAME='description') <> -1 BEGIN PRINT '=> Widening identityiq.${TABLE}.description'; ALTER TABLE identityiq.${TABLE} ALTER COLUMN description nvarchar(max) NULL END" \
				|| { echo "=> FAILED: could not widen ${TABLE}.description" >&2; exit 1; }
		else
			TYPE=$(mysql -s -N -h"${MYSQL_HOST}" -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "select data_type from information_schema.columns where table_schema='identityiq' and table_name='${TABLE}' and column_name='description'") \
				|| { echo "=> FAILED: could not read ${TABLE}.description" >&2; exit 1; }
			if [[ "${TYPE}" == "varchar" ]]; then
				echo "=> Widening identityiq.${TABLE}.description"
				mysql -h"${MYSQL_HOST}" -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "alter table identityiq.${TABLE} modify description mediumtext null" \
					|| { echo "=> FAILED: could not widen ${TABLE}.description" >&2; exit 1; }
			fi
		fi
	done
}

# The setup scripts skip an existing database, so a database left from another IIQ
# version would only fail later, when Tomcat starts. Compare it with the versions
# this build expects (constants in identityiq.jar) and stop the init container.
checkDatabaseVersion() {
	DB=$1
	CONSTANTS=$(javap -constants -cp /opt/tomcat/webapps/identityiq/WEB-INF/lib/identityiq.jar sailpoint.object.DatabaseVersion 2>/dev/null)
	EXPECTED_SCHEMA=$(echo "${CONSTANTS}" | sed -n 's/.* SCHEMA_VERSION = "\(.*\)";/\1/p')
	EXPECTED_SYSTEM=$(echo "${CONSTANTS}" | sed -n 's/.* SYSTEM_VERSION = "\(.*\)";/\1/p')
	if [[ -z "${EXPECTED_SCHEMA}" ]] || [[ -z "${EXPECTED_SYSTEM}" ]]; then
		echo "=> WARNING: could not read the expected database version from identityiq.jar; skipping the version check" >&2
		return
	fi

	QUERY="select schema_version, system_version from identityiq.spt_database_version where name='main'"
	# stderr is kept apart, since mysql warns there about the password on the command line
	QUERY_ERR=$(mktemp)
	if [[ "${DB}" == "mssql" ]]; then
		# -h -1 drops the header, -W trims padding, nocount drops "(1 rows affected)"
		FOUND=$(sqlcmd -C -N o -b -h -1 -W -s ' ' -U "${MSSQL_SA_USER:-SA}" -P "${MSSQL_SA_PASSWORD}" -S "${MSSQL_HOST}" -d identityiq -Q "set nocount on; ${QUERY}" 2>"${QUERY_ERR}")
	else
		FOUND=$(mysql -s -N -h"${MYSQL_HOST}" -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "${QUERY}" 2>"${QUERY_ERR}")
	fi
	if [[ $? -ne 0 ]]; then
		# sqlcmd prints its errors on stdout
		echo "=> FAILED: could not read the IIQ database version:" >&2
		cat "${QUERY_ERR}" >&2
		echo "${FOUND}" >&2
		rm -f "${QUERY_ERR}"
		exit 1
	fi
	rm -f "${QUERY_ERR}"
	read -r FOUND_SCHEMA FOUND_SYSTEM <<< "${FOUND}"

	if [[ "${FOUND_SCHEMA}" != "${EXPECTED_SCHEMA}" ]] || [[ "${FOUND_SYSTEM}" != "${EXPECTED_SYSTEM}" ]]; then
		echo "=> FAILED: the existing IIQ database doesn't match this build of IIQ ${IIQ_VERSION}${IIQ_PATCH:+p${IIQ_PATCH}}" >&2
		echo "     schema version: database ${FOUND_SCHEMA:-<none>}, expected ${EXPECTED_SCHEMA}" >&2
		echo "     system version: database ${FOUND_SYSTEM:-<none>}, expected ${EXPECTED_SYSTEM}" >&2
		echo "   The database is probably left over from an earlier run of the stack." >&2
		echo "   To start fresh, delete it with 'docker compose down -v' and start the stack again." >&2
		exit 1
	fi
	echo "=> Database version ${FOUND_SCHEMA} / ${FOUND_SYSTEM} matches this build"
}

awaitDatabase() {
	TYPE=$1
	
	if [[ ${TYPE} == "mysql" ]]; then
		#wait for database to start
		echo "waiting for mysql database on ${MYSQL_HOST} to come up"
		while ! mysqladmin ping -h"${MYSQL_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent ; do
			echo -ne "."
			sleep 1
		done
	else
		echo "waiting for mssql database on ${MSSQL_HOST} to come up"
		while ! sqlcmd -Q "select 1" -b -l 2 -t 2 -U SA -P "${MSSQL_SA_PASSWORD}" -S db -N o -C; do
			echo -ne "."
			sleep 1
		done
	fi
}

configureMysqlProperties() {
	# set database host in properties
	sed -ri -e "s/mysql:\/\/.*?\//mysql:\/\/${MYSQL_HOST}\//" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^dataSource.username\=.*/dataSource.username=${MYSQL_USER}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^dataSource.password\=.*/dataSource.password=${MYSQL_PASSWORD}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	
	PROPS=/opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties

	# Create plugin datasource if necessary
	if [[ -z "${PLUGINPASS}" ]]; then
		export PLUGINDB=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep url | awk -F "/" ' { print $4 } ' | awk -F "?" ' {print $1} '`
		export PLUGINUSER=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep username | awk -F "=" ' { print $2 } '`
		export PLUGINPASS=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep password | awk -F "=" ' { print $2 } '`
	fi
	
	cat /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	echo "=> Done configuring iiq.properties!"
}

configureMssqlProperties() {
	PROPS=/opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
		
	# Comment out the default MYSQL stuff if it's present
	sed -ri -e "s/^dataSource.url/#dataSource.url/" ${PROPS}
	sed -ri -e "s/^dataSource.driverClassName/#dataSource.driverClassName/" ${PROPS}
	sed -ri -e "s/^sessionFactory.hibernateProperties.hibernate.dialect/#sessionFactory.hibernateProperties.hibernate.dialect/" ${PROPS}
	sed -ri -e "s/^pluginsDataSource.url/#pluginsDataSource.url/" ${PROPS}
	sed -ri -e "s/^pluginsDataSource.driverClassName/#pluginsDataSource.driverClassName/" ${PROPS}

	sed -ri -e "s/^dataSourceAccessHistory.url/#dataSourceAccessHistory.url/" ${PROPS}
	sed -ri -e "s/^dataSourceAccessHistory.driverClassName/#dataSourceAccessHistory.driverClassName/" ${PROPS}

	# An SSB built for Oracle validates connections with "select 1 from dual", which SQL Server rejects
	sed -ri -e "s/^(dataSource|pluginsDataSource|dataSourceAccessHistory)\.validationQuery/#&/" ${PROPS}
	
	sed -ri -e "s/^dataSource.username\=.*/dataSource.username=${MSSQL_USER}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^dataSource.password\=.*/dataSource.password=${MSSQL_PASS}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^pluginsDataSource.password\=.*/pluginsDataSource.password=${MSSQL_PASS}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^dataSourceAccessHistory.password\=.*/dataSourceAccessHistory.password=${MSSQL_PASS}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	
	
	# Add the new MSSQL properties at the bottom of the file
	echo """
dataSource.url=jdbc:sqlserver://${MSSQL_HOST}:1433;databaseName=identityiq;encrypt=true;trustServerCertificate=true
dataSource.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
dataSource.validationQuery=SELECT 1
pluginsDataSource.validationQuery=SELECT 1
dataSourceAccessHistory.validationQuery=SELECT 1
sessionFactory.hibernateProperties.hibernate.dialect=sailpoint.persistence.SQLServerPagingDialect
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.MSSQLDelegate
scheduler.quartzProperties.org.quartz.jobStore.selectWithLockSQL=SELECT * FROM {0}LOCKS UPDLOCK WHERE LOCK_NAME = ?
pluginsDataSource.url=jdbc:sqlserver://${MSSQL_HOST}:1433;databaseName=identityiqPlugin;encrypt=true;trustServerCertificate=true
pluginsDataSource.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver

dataSourceAccessHistory.url=jdbc:sqlserver://${MSSQL_HOST}:1433;databaseName=identityiqah;encrypt=true;trustServerCertificate=true
dataSourceAccessHistory.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
sessionFactoryAccessHistory.hibernateProperties.hibernate.dialect=sailpoint.persistence.SQLServerUnicodeDialect

activeMQMessageServiceManager.activemqJdbcAdapter=org.apache.activemq.store.jdbc.adapter.TransactJDBCAdapter
""" >> ${PROPS}
}

importIIQObjects() {
	DB_SPADMIN_PRESENT=`echo "get Identity spadmin" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console`
	
	if [[ `echo "x${DB_SPADMIN_PRESENT}" | grep "Unknown object"` ]]
	then
		echo "=> No spadmin user in database, importing objects"
		iiq "import init.xml"
		iiq "import init-lcm.xml"
		if [[ ! -z "${IIQ_PATCH}" ]]; then
			echo "" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq patch ${IIQ_PATCH}
		fi
		if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/config/seri ]]; then
			iiq "import seri/init-seri.xml"
		fi
	        if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/config/init-acceleratorpack.xml ]]; then
	                iiq "import init-acceleratorpack.xml"
	        fi
		if [[ -e /opt/iiq/objects ]]; then
			if [[ -e /tmp/import.xml ]]; then
				rm /tmp/import.xml
			fi
			echo "<?xml version='1.0' encoding='UTF-8'?>" >> /tmp/import.xml
			echo '<!DOCTYPE sailpoint PUBLIC "sailpoint.dtd" "sailpoint.dtd">' >> /tmp/import.xml
			echo "<sailpoint>" >> /tmp/import.xml
			for file in `find /opt/iiq/objects -name \*.xml | sort`
			do
				echo "<ImportAction name='include' value='${file}'/>" >> /tmp/import.xml
			done
			echo "</sailpoint>" >> /tmp/import.xml
			echo " => Importing custom objects"
			iiq "import /tmp/import.xml"
		fi
	else
		if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/config/sp.init-custom.xml ]]; then
			echo "=> This appears to be an existing install; importing SSB customizations only"
			iiq "import sp.init-custom.xml"
		fi
	fi
	if [[ -e /opt/iiq/plugins ]]; then
		for file in `ls /opt/iiq/plugins/*.zip`
		do
			iiq "plugin install $file"
		done
	fi
}

export PATH=$PATH:/opt/mssql-tools18/bin

echo "=> Unpacking IIQ into /opt/tomcat/webapps"

# unzip IIQ from the mounted directory
mkdir -p /opt/tomcat/webapps/identityiq
pushd /opt/tomcat/webapps/identityiq

unzip -q /opt/iiq/identityiq.war

for file in $(ls /opt/iiq/patch/*.jar)
do
	echo "=> Including patch JAR $file"
	unzip -q -o $file
done

for file in $(ls /opt/iiq/efix/*.jar)
do
	echo "=> Including efix ZIP $file"
	unzip -q -o $file
done

popd

# An SSB can point IIQ at a keystore (keyStore.file, keyStore.passwordFile) that
# only exists on the customer's servers. Comment those settings out so IIQ uses
# its default key; values the SSB encrypted with the customer's key won't decrypt.
if grep -qE '^[[:space:]]*keyStore\.' /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties; then
	echo "=> Commenting out the custom keyStore settings in iiq.properties"
	sed -ri -e 's/^[[:space:]]*keyStore\./#&/' /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
fi

if [[ -z "${IIQ_VERSION}" ]]; then
	export IIQ_VERSION=$(unzip -p /opt/tomcat/webapps/identityiq/WEB-INF/lib/identityiq.jar META-INF/MANIFEST.MF | grep Implementation-Version | awk -F "[ p]" '{print $3}')
	export IIQ_PATCH=$(unzip -p /opt/tomcat/webapps/identityiq/WEB-INF/lib/identityiq.jar META-INF/MANIFEST.MF | grep Implementation-Version | awk -F "[ p]" '{print $4}' | grep '[0-9]')
fi

if [[ "${DATABASE_TYPE}" == "local" ]]
then
	INIT_LOCAL=1
	DATABASE_TYPE=mysql
	export MYSQL_HOST=localhost
	export MYSQL_USER=identityiq
	export MYSQL_PASSWORD=identityiq
	export MYSQL_ROOT_PASSWORD=password
	export MYSQL_DATABASE=identityiq
	export PLUGINDB=identityiqPlugin
	export PLUGINUSER=identityiqPlugin
	export PLUGINPASS=identityiqPlugin
	# Starts the mysqld server in the background, then returns
	/mysql-local.sh
fi

if [[ "${DATABASE_TYPE}" == "mysql" ]] || [[ -z "${DATABASE_TYPE}" ]]
then
	awaitDatabase mysql;
	configureMysqlProperties;
else 
	awaitDatabase mssql;
	sleep 10;
	configureMssqlProperties;
fi

chmod u+x /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq

if [[ -z "${INIT}" ]]
then
	if [[ -z "${INIT_LOCAL}" ]]
	then
		# Get ourselves a counter
		while [[ -z "${COUNTER}" ]]; do
			COUNTER=`nc counter 12345`
			sleep 1
		done

		echo "=> This node is iiq$COUNTER"
		export NODE="iiq$COUNTER"

		export JAVA_OPTS="-Diiq.hostname=$NODE"
	else
		export JAVA_OPTS="$JAVA_OPTS -Diiq.hostname=iiq1"
	fi
fi

echo "=> Copying files from /opt/iiq/lib to WEB-INF/lib"
cp /opt/iiq/lib/*.jar /opt/tomcat/webapps/identityiq/WEB-INF/lib

if [[ ! -z "${INIT}" ]] || [[ ! -z "${INIT_LOCAL}" ]]
then
	# The setup scripts create this file when they create a new IIQ schema
	rm -f /tmp/iiq-new-database

	if [[ "${DATABASE_TYPE}" == "mysql" ]] || [[ -z "${DATABASE_TYPE}" ]]
	then
		/database-setup.mysql.sh
		SSB_DB=mysql
	else
		/database-setup.mssql.sh
		SSB_DB=mssql
	fi

	if [[ ! -e /tmp/iiq-new-database ]]; then
		checkDatabaseVersion "${SSB_DB}"
	fi

	# Custom tables from the SSB's db folder, converted for this database. Only
	# on a new database, since the scripts' inserts aren't safe to repeat.
	# The WAR's own iiq.properties still has the SSB's JDBC URL, which says what
	# database a script is for when its syntax doesn't.
	if [[ -e /tmp/iiq-new-database ]] && [[ -d /opt/iiq/db ]]; then
		SSB_URL=$(unzip -p /opt/iiq/identityiq.war WEB-INF/classes/iiq.properties | tr -d '\r' | grep -E '^[[:space:]]*dataSource\.url[[:space:]]*=' | tail -1 | cut -d= -f2-)
		python3 /ssb-db-scripts.py --db "${SSB_DB}" --source-url "${SSB_URL}" /opt/iiq/db
	fi

	widenDescriptionColumns "${SSB_DB}"

	if [ -z "${SKIP_DEMO_IMPORT}" ]
	then
		echo "=> Importing example company data for HR"
		cd /opt/sql
		unzip -q employees.zip
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/sql/employees.sql

		echo "=> Importing example target system"
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/sql/target.sql

		# It is okay if this fails
		mysql -s -N -h${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e "grant select on hr.* to 'identityiq'; grant select on hr.* to 'identityiqPlugin';"
	fi

	# Import init.xml, etc
	importIIQObjects;
fi

if [[ -z "${INIT}" ]] || [[ ! -z "${INIT_LOCAL}" ]]
then
	# Start up Tomcat if not the init container *or* if we're doing a local build
	if [[ ! -z "${TOMCAT_MEMORY}" ]]; then
		export JAVA_OPTS="${JAVA_OPTS} -Xmx${TOMCAT_MEMORY}"
	fi
	/opt/tomcat/bin/catalina.sh run | tee -a /opt/tomcat/logs/catalina.out
else
	echo "=> Initialization complete, exiting!"
fi
