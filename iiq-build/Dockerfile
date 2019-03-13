FROM tomcat:8.5

MAINTAINER Devin Rosenbauer <devin@identityworksllc.com>

# Based on an original Dockerfile by Steffan Sperling, but modified beyond recognition!

# Fix sh
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Install dependencies
RUN apt-get update && \
apt-get install -y apt-utils wget unzip tar mysql-client netcat curl openssh-server openssh-client supervisor openjdk-8-jdk nano less ldap-utils apt-transport-https

RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
RUN curl https://packages.microsoft.com/config/debian/9/prod.list | tee /etc/apt/sources.list.d/msprod.list
RUN apt-get update 
RUN ACCEPT_EULA=Y apt-get install -y mssql-tools unixodbc-dev

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

VOLUME "/opt/iiq"

RUN mkdir -p /opt/tomcat/webapps/ROOT
COPY index.html /opt/tomcat/webapps/ROOT

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CATALINA_HOME /opt/tomcat
ENV CATALINA_BASE /opt/tomcat
ENV PATH $PATH:$CATALINA_HOME/bin

EXPOSE 22 8009 8080
VOLUME "/opt/tomcat/webapps"
VOLUME "/opt/iiq/import-list"
VOLUME "/opt/iiq/imports"
WORKDIR /opt/tomcat

RUN mkdir -p /var/run/sshd /var/log/supervisor

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

COPY healthcheck.sh /opt/healthcheck.sh
RUN chmod +x /opt/healthcheck.sh
HEALTHCHECK --start-period=120s --timeout=10s --interval=10s --retries=10 CMD /opt/healthcheck.sh

COPY src/bootstrap.ldif /bootstrap.ldif

# Launch IIQ
CMD ["/usr/bin/supervisord"]
