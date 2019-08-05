#!/bin/bash

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
		while ! sqlcmd -Q "select 1" -b -l 2 -t 2 -U SA -P "${MSSQL_SA_PASSWORD}" -S db ; do
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
	export PLUGINDB=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep url | awk -F "/" ' { print $4 } ' | awk -F "?" ' {print $1} '`
	export PLUGINUSER=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep username | awk -F "=" ' { print $2 } '`
	export PLUGINPASS=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep password | awk -F "=" ' { print $2 } '`
	
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
dataSource.url=jdbc:sqlserver://db:1433;databaseName=identityiq;
dataSource.driverClassName=com.microsoft.sqlserver.jdbc.SQLServerDriver
sessionFactory.hibernateProperties.hibernate.dialect=sailpoint.persistence.SQLServerPagingDialect
scheduler.quartzProperties.org.quartz.jobStore.driverDelegateClass=org.quartz.impl.jdbcjobstore.MSSQLDelegate
scheduler.quartzProperties.org.quartz.jobStore.selectWithLockSQL=SELECT * FROM {0}LOCKS UPDLOCK WHERE LOCK_NAME = ?
pluginsDataSource.url=jdbc:sqlserver://db:1433;databaseName=identityiqPlugin
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
		if [[ -e /opt/iiq/imports ]]; then
			pushd /opt/iiq/imports
			for file in `ls`; do
				cp -rf "$file" /opt/tomcat/webapps/identityiq/WEB-INF/config/
			done
			popd
			if [[ -e /opt/iiq/auto-import-list ]]; then
				for item in `cat /opt/iiq/auto-import-list`; do
					iiq "import $item"
				done
			fi
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

export PATH=$PATH:/opt/mssql-tools/bin

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
	# Get ourselves a counter
	while [[ -z "${COUNTER}" ]]; do
		COUNTER=`nc counter 12345`
		sleep 1
	done

	echo "=> This node is iiq$COUNTER"
	export NODE="iiq$COUNTER"

	export JAVA_OPTS="-Diiq.hostname=$NODE"

	if [[ -z "${INIT_LOCAL}" ]]
	then
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
		mysql -s -N -h${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e "grant select on hr.* to 'identityiq';"
	fi

	# Import init.xml, etc
	importIIQObjects;

	# Flag the "done" service as done
	nc done 40000
fi

if [[ -z "${INIT}" ]] || [[ ! -z "${INIT_LOCAL}" ]]
then
	# Start up Tomcat if not the init container *or* if we're doing a local build
	/opt/tomcat/bin/catalina.sh run | tee -a /opt/tomcat/logs/catalina.out
else
	echo "=> Initialization complete, exiting!"
fi
