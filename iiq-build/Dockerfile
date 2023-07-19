FROM eclipse-temurin:11-jdk-focal as iiqCommon

WORKDIR /

COPY fetch-package.sh ./

RUN apt-get update && \
    apt-get install --no-install-recommends -y git jq curl ca-certificates unzip && \
    chmod +x fetch-package.sh && \
    ./fetch-package.sh

FROM tomcat:9-jdk11-temurin-focal as tomcat

RUN mv /usr/local/tomcat /opt/tomcat && \
    mv /opt/tomcat/webapps.dist/manager /opt/tomcat/webapps

# Add admin/s3cret user
ADD tomcat-users.xml /opt/tomcat/conf/
run mkdir -p /opt/tomcat/conf/Catalina/localhost/
ADD manager.xml /opt/tomcat/conf/Catalina/localhost

# Add demo employee data
RUN mkdir -p /opt/sql
COPY sql/employees.zip /opt/sql/
COPY sql/target.sql /opt/sql/

RUN mkdir -p /opt/iiq && \
    mkdir -p /opt/iiq/imports && \
    mkdir -p /opt/iiq/plugins && \
    mkdir -p /opt/iiq/patch && \
    mkdir -p /opt/iiq/efix && \
    mkdir -p /opt/iiq/certs && \
    mkdir -p /opt/tomcat/webapps/ROOT && \
    mkdir -p /etc/mysql/conf.d

COPY sailpoint/identityiq.war /opt/iiq/identityiq.war
COPY --from=iiqCommon ./iiq-common-public.jar /opt/iiq/iiq-common-public.jar
COPY src/ /opt/iiq/

COPY index.html /opt/tomcat/webapps/ROOT

COPY healthcheck.sh /opt/healthcheck.sh

COPY *.sh /

RUN chmod +x /*.sh && \
    chmod 755 /mysql-local-startup.sh && \
    /import-certs.sh && \
    cp /opt/iiq/bootstrap.ldif /bootstrap.ldif

FROM eclipse-temurin:11-jdk-focal as primary

LABEL maintainer="Devin Rosenbauer <devin@identityworksllc.com>"
MAINTAINER Devin Rosenbauer <devin@identityworksllc.com>

# All the OS updates
RUN rm /bin/sh && ln -s /bin/bash /bin/sh && \
    apt-get update && \
    apt-get install --no-install-recommends -y apt-utils wget unzip tar mysql-client netcat curl supervisor nano less ldap-utils apt-transport-https gnupg libaio1 libaio-dev && \
    curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl https://packages.microsoft.com/config/ubuntu/20.04/prod.list | tee /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    apt-get install -y locales && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen && \
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /opt && \
    rm -rf /usr/local/tomcat

COPY --from=tomcat /opt /opt
COPY --from=tomcat *.sh /
COPY my.cnf /etc/mysql

ENV CATALINA_HOME /opt/tomcat
ENV CATALINA_BASE /opt/tomcat
ENV PATH $PATH:$CATALINA_HOME/bin

EXPOSE 22 8009 8080
WORKDIR /opt/tomcat

RUN chmod +x /opt/healthcheck.sh
HEALTHCHECK --start-period=120s --timeout=10s --interval=10s --retries=10 CMD /opt/healthcheck.sh

# Default environment is a 'local' database for standalone-ness
# Compose or command line -e will override this
ENV DATABASE_TYPE=local

# Launch IIQ
CMD ["/entrypoint.sh"]
