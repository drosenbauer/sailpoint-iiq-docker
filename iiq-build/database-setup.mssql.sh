# Install script to setup a new IIQ database with mysql
# Environment variables:
#   MYSQL_ROOT_PASSWORD
#   PLUGINDB
#   PLUGINUSER
#   PLUGINPASS
#   SKIP_DEMO_IMPORT

#check if database schema is already there
export DB_SCHEMA_VERSION=$(sqlcmd -U SA -P ${MSSQL_SA_PASSWORD} -S db -d identityiq -Q "select schema_version from identityiq.spt_database_version;")
if [ -z "$DB_SCHEMA_VERSION" ]
then
	echo "=> No schema present, creating IIQ schema in MSSQL DB" 
	echo "" | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq schema

	# create database schema
	if [[ -e /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.sqlserver ]]; then
		sed -ri -e "s/PASSWORD='identityiq'/PASSWORD='${MSSQL_PASS}'/" /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.sqlserver
		sed -ri -e "s/PASSWORD='identityiqPlugin'/PASSWORD='${MSSQL_PASS}'/" /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.sqlserver
		sqlcmd -U SA -P ${MSSQL_SA_PASSWORD} -S db -b -i /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.sqlserver
	else
		sed -ri -e "s/PASSWORD='identityiq'/PASSWORD='${MSSQL_PASS}'/" /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables-${IIQ_VERSION}.sqlserver
		sed -ri -e "s/PASSWORD='identityiqPlugin'/PASSWORD='${MSSQL_PASS}'/" /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables.sqlserver
		sqlcmd -U SA -P ${MSSQL_SA_PASSWORD} -S db -b -i /opt/tomcat/webapps/identityiq/WEB-INF/database/create_identityiq_tables-${IIQ_VERSION}.sqlserver
	fi
	
	echo "=> Done creating database, checking for upgrades..."
	cd /opt/tomcat/webapps/identityiq/WEB-INF/database/
	if [[ -e upgrade_identityiq_tables.sqlserver ]]; then
		echo "=> Installing custom upgrade script"
		sqlcmd -U SA -P ${MSSQL_SA_PASSWORD} -S db -i upgrade_identityiq_tables.sqlserver
	else
		for upgrade in `ls upgrade_identityiq_tables-${IIQ_VERSION}*.sqlserver | sort`
		do
			echo "=> Installing upgrade $upgrade"
			sqlcmd -U SA -P ${MSSQL_SA_PASSWORD} -S db -i $upgrade
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