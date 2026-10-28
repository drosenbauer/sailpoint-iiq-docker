ARG TOMCAT_VERSION=9-jdk17-temurin-jammy
ARG JDK_VERSION=17-jdk-jammy

FROM eclipse-temurin:17-jdk-jammy AS iiqcstage

WORKDIR /

COPY fetch-package.sh ./

RUN echo "Acquire::http::Pipeline-Depth 0;" > /etc/apt/apt.conf.d/99custom && \
    echo "Acquire::http::No-Cache true;" >> /etc/apt/apt.conf.d/99custom && \
    echo "Acquire::BrokenProxy    true;" >> /etc/apt/apt.conf.d/99custom

RUN apt-get update && \
    apt-get install --no-install-recommends -y git jq curl ca-certificates unzip && \
    chmod +x fetch-package.sh && \
    ./fetch-package.sh

FROM tomcat:${TOMCAT_VERSION} AS tomcat

RUN mv /usr/local/tomcat /opt/tomcat && \
    mv /opt/tomcat/webapps.dist/manager /opt/tomcat/webapps

# Add admin/s3cret user
ADD tomcat-users.xml /opt/tomcat/conf/
RUN mkdir -p /opt/tomcat/conf/Catalina/localhost/
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
    mkdir -p /opt/iiq/lib && \
    mkdir -p /opt/tomcat/webapps/ROOT && \
    mkdir -p /etc/mysql/conf.d

COPY sailpoint/identityiq.war /opt/iiq/identityiq.war
COPY --from=iiqcstage ./iiq-common-public.jar /opt/iiq/lib/iiq-common-public.jar
COPY src/ /opt/iiq/

COPY index.html /opt/tomcat/webapps/ROOT

COPY healthcheck.sh /opt/healthcheck.sh

COPY *.sh /

RUN chmod +x /*.sh && \
    chmod 755 /mysql-local-startup.sh && \
    /import-certs.sh && \
    cp /opt/iiq/bootstrap.ldif /bootstrap.ldif

FROM eclipse-temurin:${JDK_VERSION} AS primary

LABEL maintainer="Devin Rosenbauer <devin@instrumentalid.com>"
LABEL org.opencontainers.image.authors="Devin Rosenbauer <devin@instrumentalid.com>"
LABEL org.opencontainers.image.documentation="https://github.com/drosenbauer/sailpoint-iiq-docker"
LABEL org.opencontainers.image.source="https://github.com/drosenbauer/sailpoint-iiq-docker"
LABEL org.opencontainers.image.vendor="Instrumental Identity"
LABEL org.opencontainers.image.title="SailPoint IIQ"

RUN echo "Acquire::http::Pipeline-Depth 0;" > /etc/apt/apt.conf.d/99custom && \
    echo "Acquire::http::No-Cache true;" >> /etc/apt/apt.conf.d/99custom && \
    echo "Acquire::BrokenProxy    true;" >> /etc/apt/apt.conf.d/99custom

# All the OS updates
# libaio1 was renamed libaio1t64 in Ubuntu 24.04 (noble); the Microsoft repo is keyed by Ubuntu version;
# the 22.04 list has no signed-by, so the key also goes in trusted.gpg.d
RUN rm /bin/sh && ln -s /bin/bash /bin/sh && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get update && \
    apt-get install --no-install-recommends -y apt-utils wget unzip tar mysql-client netcat-traditional curl supervisor nano less ldap-utils apt-transport-https gnupg ca-certificates && \
    (apt-get install --no-install-recommends -y libaio1t64 || apt-get install --no-install-recommends -y libaio1) && \
    . /etc/os-release && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    cp /usr/share/keyrings/microsoft-prod.gpg /etc/apt/trusted.gpg.d/microsoft-prod.gpg && \
    curl -fsSL https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/prod.list | tee /etc/apt/sources.list.d/mssql-release.list && \
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
COPY --from=tomcat *.ldif /
COPY my.cnf /etc/mysql

ENV CATALINA_HOME=/opt/tomcat
ENV CATALINA_BASE=/opt/tomcat
ENV PATH=$PATH:$CATALINA_HOME/bin

EXPOSE 22 8009 8080
WORKDIR /opt/tomcat

RUN chmod +x /opt/healthcheck.sh
HEALTHCHECK --start-period=120s --timeout=10s --interval=10s --retries=10 CMD /opt/healthcheck.sh

# Default environment is a 'local' database for standalone-ness
# Compose or command line -e will override this
ENV DATABASE_TYPE=local

# Launch IIQ
CMD ["/entrypoint.sh"]
