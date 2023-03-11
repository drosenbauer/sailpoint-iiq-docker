FROM tomcat:8.5-jre8

LABEL maintainer="Devin Rosenbauer <devin@identityworksllc.com>"
MAINTAINER Devin Rosenbauer <devin@identityworksllc.com>

# Based on an original Dockerfile by Steffan Sperling, but modified beyond recognition!
# Fix sh
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Install gnupg
RUN apt-get update && apt-get install -y gnupg

# Install dependencies
RUN apt-get update && \
apt-get install --no-install-recommends -y apt-utils wget unzip tar mysql-client netcat curl supervisor nano less ldap-utils apt-transport-https && \
curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
curl https://packages.microsoft.com/config/debian/9/prod.list | tee /etc/apt/sources.list.d/msprod.list && \
apt-get update && \
apt-get install -y locales && \
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
locale-gen && \
ACCEPT_EULA=Y apt-get install -y mssql-tools unixodbc-dev && \
rm -rf /var/lib/apt/lists/*

# Move the default image location to the one this is expecting
RUN mv /usr/local/tomcat /opt/tomcat

# Add admin/admin user
ADD tomcat-users.xml /opt/tomcat/conf/
run mkdir -p /opt/tomcat/conf/Catalina/localhost
ADD manager.xml /opt/tomcat/conf/Catalina/localhost

# Add demo employee data
RUN mkdir -p /opt/sql
COPY sql/employees.zip /opt/sql/
COPY sql/target.sql /opt/sql/

RUN mkdir -p /opt/iiq && mkdir -p /opt/iiq/imports && mkdir -p /opt/iiq/plugins && mkdir -p /opt/iiq/patch && mkdir -p /opt/iiq/efix && mkdir -p /opt/iiq/certs

COPY src/identityiq.war /opt/iiq/identityiq.war
#COPY src/imports/* /opt/iiq/imports/
COPY src/objects/ /opt/iiq/objects/
COPY src/plugins/* /opt/iiq/plugins/
COPY src/patch/* /opt/iiq/patch/
COPY src/efix/* /opt/iiq/efix/
COPY src/certs/* /opt/iiq/certs

RUN mkdir -p /opt/tomcat/webapps/ROOT
COPY index.html /opt/tomcat/webapps/ROOT

COPY database-setup.mysql.sh /database-setup.mysql.sh
COPY database-setup.mssql.sh /database-setup.mssql.sh
COPY import-certs.sh /import-certs.sh
COPY mysql-local.sh /mysql-local.sh
COPY mysql-local-startup.sh /mysql-local-startup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /*.sh
RUN chmod 755 /mysql-local-startup.sh

RUN /import-certs.sh

ENV CATALINA_HOME /opt/tomcat
ENV CATALINA_BASE /opt/tomcat
ENV PATH $PATH:$CATALINA_HOME/bin

EXPOSE 22 8009 8080
VOLUME "/opt/tomcat/webapps"
WORKDIR /opt/tomcat

COPY healthcheck.sh /opt/healthcheck.sh
RUN chmod +x /opt/healthcheck.sh
HEALTHCHECK --start-period=120s --timeout=10s --interval=10s --retries=10 CMD /opt/healthcheck.sh

# Default environment is a 'local' database for standalone-ness
# Compose will override this
ENV DATABASE_TYPE=local

COPY src/bootstrap.ldif /bootstrap.ldif

# Launch IIQ
CMD ["/entrypoint.sh"]
