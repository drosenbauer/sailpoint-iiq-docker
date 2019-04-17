#!/bin/bash
set -x

#check environment variables and set some defaults
if [ -z "${MYSQL_HOST}" ]
then
	export MYSQL_HOST=db
fi
if [ -z "${MYSQL_USER}" ]
then
	export MYSQL_USER=root
fi
if [ -z "${MYSQL_PASSWORD}" ]
then
	export MYSQL_PASSWORD=secr3tPa55word
fi

# unzip IIQ from the mounted directory
mkdir -p /opt/tomcat/webapps/identityiq
pushd /opt/tomcat/webapps/identityiq
unzip -q /opt/iiq/identityiq.war
popd

#wait for database to start
echo "waiting for database on ${MYSQL_HOST} to come up"
while ! mysqladmin ping -h"${MYSQL_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent ; do
	echo -ne "."
	sleep 1
done

PROPS=/opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties

# set database host in properties
sed -ri -e "s/mysql:\/\/.*?\//mysql:\/\/${MYSQL_HOST}\//" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
sed -ri -e "s/^dataSource.username\=.*/dataSource.username=${MYSQL_USER}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
sed -ri -e "s/^dataSource.password\=.*/dataSource.password=${MYSQL_PASSWORD}/" /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
cat /opt/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
echo "=> Done configuring iiq.properties!"

if [ -z "${SECONDARY}" ]
then
	echo "=> Importing dummy company data for HR"
	cd /opt/sql
	unzip -q employees.zip
	mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < /opt/sql/employees.sql
	mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < /opt/sql/target.sql
	mysql -s -N -hdb -uroot -p${MYSQL_ROOT_PASSWORD} -e "grant select on hr.* to 'identityiq';"
fi		

# Create plugin datasource if necessary
PLUGINDB=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep url | awk -F "/" ' { print $4 } ' | awk -F "?" ' {print $1} '`
PLUGINUSER=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep username | awk -F "=" ' { print $2 } '`
PLUGINPASS=`grep pluginsDataSource ${PROPS} | grep -v "#" | grep password | awk -F "=" ' { print $2 } '`

if [ ! -z "${SECONDARY}" ]
then
	echo "=> Waiting for iiq1 to come up"
	while ! curl --output /dev/null --silent --head --fail http://${IIQ_MASTER_NAME}:8080; do sleep 1; done;
	echo "=> iiq1 is up; resuming startup..."
fi

chmod u+x /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq

#check if database schema is already there
export DB_SCHEMA_VERSION=$(mysql -s -N -hdb -uroot -p${MYSQL_ROOT_PASSWORD} -e "select schema_version from identityiq.spt_database_version;")
if [ -z "$DB_SCHEMA_VERSION" ]
then
	echo "=> No schema present, creating IIQ schema in DB" 
	echo "" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq schema

	echo "=> Installing the plugin database"
	if [[ ! -z $PLUGINDB ]]; then
		echo "=> Creating the plugin database using the following script:"
		mkdir -p /tmp/sql
		echo "create user if not exists ${PLUGINUSER} identified by '${PLUGINPASS}';" > /tmp/sql/plugindb.sql
		echo "CREATE DATABASE ${PLUGINDB};" >> /tmp/sql/plugindb.sql
		echo "GRANT ALL PRIVILEGES ON ${PLUGINDB}.* TO '${PLUGINUSER}' IDENTIFIED BY '${PLUGINPASS}';" >> /tmp/sql/plugindb.sql
		echo "GRANT ALL PRIVILEGES ON ${PLUGINDB}.* TO '${PLUGINUSER}'@'%' IDENTIFIED BY '${PLUGINPASS}';" >> /tmp/sql/plugindb.sql
		echo "GRANT ALL PRIVILEGES ON ${PLUGINDB}.* TO '${PLUGINUSER}'@'localhost' IDENTIFIED BY '${PLUGINPASS}';" >> /tmp/sql/plugindb.sql
		cat /tmp/sql/plugindb.sql
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < /tmp/sql/plugindb.sql
	fi

	# create database schema
	if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.mysql ]]; then
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.mysql
	else
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables-${IIQ_VERSION}.mysql
	fi
	if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/database/plugins/create_identityiq_plugins_db.mysql ]]; then
		echo "=> Creating plugin database"
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < /opt/tomcat/webapps/identityiq/WEB-INF/database/plugins/create_identityiq_plugins_db.mysql
	fi

	echo "=> Done creating database, checking for upgrades..."
	cd /opt/tomcat/webapps/identityiq/WEB-INF/database/
	if [[ -e upgrade_identityiq_tables.mysql ]]; then
		echo "=> Installing custom upgrade script"
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < upgrade_identityiq_tables.mysql
	else
		for upgrade in `ls upgrade_identityiq_tables-${IIQ_VERSION}*.mysql | sort`
		do
			echo "=> Installing upgrade $upgrade"
			mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hdb < $upgrade
		done
	fi
	
	echo "=> Importing demo LDAP objects"
	ldapmodify -h ldap -D "cn=admin,dc=sailpoint,dc=demo" -w spadmin -f /bootstrap.ldif
else
	echo "=> Database already set up, version "$DB_SCHEMA_VERSION" found, starting IIQ directly";
fi
export DB_SPADMIN_PRESENT=$(mysql -s -N -hdb -uroot -p${MYSQL_ROOT_PASSWORD} -e "select name from identityiq.spt_identity where name='spadmin';")
if [ -z $DB_SPADMIN_PRESENT ]
then
	echo "=> No spadmin user in database, importing objects"
	echo "import init.xml" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console
	echo "import init-lcm.xml" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console
	if [[ ! -z "${IIQ_PATCH}" ]]; then
		echo "" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq patch ${IIQ_PATCH}
	fi
	if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/config/seri ]]; then
		echo "import seri/init-seri.xml" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console
	fi
        if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/config/init-acceleratorpack.xml ]]; then
                echo "import init-acceleratorpack.xml" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console
        fi
	if [[ -e /opt/iiq/imports ]]; then
		pushd /opt/iiq/imports
		for file in `ls`; do
			cp -rf "$file" /opt/tomcat/webapps/identityiq/WEB-INF/config/
		done
		popd
		if [[ -e /opt/iiq/auto-import-list ]]; then
			for item in `cat /opt/iiq/auto-import-list`; do
				echo "import $item" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console
			done
		fi
	fi
fi

/opt/tomcat/bin/catalina.sh run | tee -a /opt/tomcat/logs/catalina.out

