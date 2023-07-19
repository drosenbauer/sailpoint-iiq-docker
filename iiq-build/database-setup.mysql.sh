# Install script to setup a new IIQ database with mysql
# Environment variables:
#   MYSQL_ROOT_PASSWORD
#   PLUGINDB
#   PLUGINUSER
#   PLUGINPASS
#   SKIP_DEMO_IMPORT

#check if database schema is already there
export DB_SCHEMA_VERSION=$(mysql -s -N -h${MYSQL_HOST} -uroot -p${MYSQL_ROOT_PASSWORD} -e "select schema_version from identityiq.spt_database_version;")
if [ -z "$DB_SCHEMA_VERSION" ]
then
	echo "=> No schema present, creating IIQ schema in DB" 
	echo "" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq schema

	echo "=> Installing the plugin database"
	if [[ ! -z $PLUGINDB ]]; then
		echo "=> Creating the plugin database using the following script:"
		mkdir -p /tmp/sql
		echo "create user if not exists '${PLUGINUSER}' identified by '${PLUGINPASS}';" > /tmp/sql/plugindb.sql
		echo "CREATE DATABASE ${PLUGINDB};" >> /tmp/sql/plugindb.sql
		echo "GRANT ALL PRIVILEGES ON ${PLUGINDB}.* TO '${PLUGINUSER}';" >> /tmp/sql/plugindb.sql
		cat /tmp/sql/plugindb.sql
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /tmp/sql/plugindb.sql
	fi

	# create database schema
	if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.mysql ]]; then
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.mysql
	else
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables-${IIQ_VERSION}.mysql
	fi
	if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/database/plugins/create_identityiq_plugins_db.mysql ]]; then
		echo "=> Creating plugin database"
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < /opt/tomcat/webapps/identityiq/WEB-INF/database/plugins/create_identityiq_plugins_db.mysql
	fi

	echo "=> Done creating database, checking for upgrades..."
	cd /opt/tomcat/webapps/identityiq/WEB-INF/database/
	if [[ -e upgrade_identityiq_tables.mysql ]]; then
		echo "=> Installing custom upgrade script"
		mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < upgrade_identityiq_tables.mysql
	else
		for upgrade in `ls upgrade_identityiq_tables-${IIQ_VERSION}*.mysql | sort`
		do
			echo "=> Installing upgrade $upgrade"
			mysql -uroot -p${MYSQL_ROOT_PASSWORD} -h${MYSQL_HOST} < $upgrade
		done
	fi
	
	if [ -z "${SKIP_DEMO_IMPORT}" ]
	then
		echo "=> Importing demo LDAP objects"
		ldapmodify -h ldap -D "cn=admin,dc=sailpoint,dc=demo" -w spadmin -f /bootstrap.ldif
	fi
else
	echo "=> Database already set up, version "$DB_SCHEMA_VERSION" found, starting IIQ directly";
fi
