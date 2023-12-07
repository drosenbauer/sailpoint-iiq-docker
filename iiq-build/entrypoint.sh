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
#   - If there are no objects in IIQ, imports init.xml and init-lcm.xml
#   - If there are any object XMLs in /opt/iiq/objects, imports them
#   - If there are any objects installed, just imports sp.init-custom.xml
#   - Installs any plugins in /opt/iiq/plugins
#   - Starts Tomcat, listening on port 8080

iiq() {
	COMMAND=$1
	echo "Executing iiq console command '$COMMAND'"
	echo $COMMAND | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console
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
		echo "waiting for mssql database on ${MYSQL_HOST} to come up"
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
	
	sed -ri -e "s/^dataSource.username\=.*/dataSource.username=${MSSQL_USER}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^dataSource.password\=.*/dataSource.password=${MSSQL_PASS}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
#	sed -ri -e "s/^pluginsDataSource.username\=.*/pluginsDataSource.username=${MSSQL_USER}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	sed -ri -e "s/^pluginsDataSource.password\=.*/pluginsDataSource.password=${MSSQL_PASS}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
	
	
	# Add the new MSSQL properties 
	echo """
dataSource.url=jdbc:sqlserver://${MSSQL_HOST}:1433;databaseName=identityiq;
dataSource.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
sessionFactory.hibernateProperties.hibernate.dialect=sailpoint.persistence.SQLServerPagingDialect
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.MSSQLDelegate
scheduler.quartzProperties.org.quartz.jobStore.selectWithLockSQL=SELECT * FROM {0}LOCKS UPDLOCK WHERE LOCK_NAME = ?
pluginsDataSource.url=jdbc:sqlserver://${MSSQL_HOST}:1433;databaseName=identityiqPlugin
pluginsDataSource.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
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

# unzip IIQ from the mounted directory
mkdir -p /opt/tomcat/webapps/identityiq
pushd /opt/tomcat/webapps/identityiq
unzip -q /opt/iiq/identityiq.war
for file in /opt/iiq/patch/*.jar
do
	echo "=> Including patch JAR $file"
	unzip -q -o $file
done
for file in /opt/iiq/efix/*.jar
do
	echo "=> Including efix ZIP $file"
	unzip -q -o $file
done
popd

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

if [[ "${DATABASE_TYPE}" == "mysql" ]]
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

		echo "=> Waiting for the init container to finish initialization"
		sleep 10
		UP=0
		while [[ $UP == "0" ]]; do
			ISDONE=`nc done 40001`
			if [[ $ISDONE == "DONE" ]]; then
				UP=1
			else
				echo "Still waiting..."
			fi
			sleep 10
		done
		echo "=> Database is ready; resuming startup..."
	else
		export JAVA_OPTS="$JAVA_OPTS -Diiq.hostname=iiq1"
	fi
fi

if [[ ! -z "${INIT}" ]] || [[ ! -z "${INIT_LOCAL}" ]]
then
	if [[ "${DATABASE_TYPE}" == "mysql" ]]
	then	
		/database-setup.mysql.sh
	else
		/database-setup.mssql.sh
	fi

	if [ -z "${SKIP_DEMO_IMPORT}" ]
	then
		echo "=> Importing dummy company data for HR"
		cd /opt/sql
		unzip -q employees.zip
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/sql/employees.sql
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/sql/target.sql
		mysql -s -N -h${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e "grant select on hr.* to 'identityiq'; grant select on hr.* to 'identityiqPlugin';"
	fi

	# Import init.xml, etc
	importIIQObjects;

	# Done service will only exist in the swarm context
	if [[ -z "${INIT_LOCAL}" ]]; then
		# Flag the "done" service as done
		nc done 40000
	fi
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
