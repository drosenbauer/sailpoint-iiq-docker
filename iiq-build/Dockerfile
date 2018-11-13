FROM ubuntu:bionic

MAINTAINER Devin Rosenbauer <devin@identityworksllc.com>

# Based on an original Dockerfile by Steffan Sperling, but modified beyond recognition!

ENV TOMCAT_VERSION 8.5.34

# Fix sh
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Install dependencies
RUN apt-get update && \
apt-get install -y apt-utils wget unzip tar mysql-client netcat curl openssh-server openssh-client supervisor openjdk-8-jdk nano less

# Get Tomcat
RUN wget --quiet --no-cookies http://www-eu.apache.org/dist/tomcat/tomcat-8/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz -O /tmp/tomcat.tgz && \
tar xzvf /tmp/tomcat.tgz -C /opt && \
mv /opt/apache-tomcat-${TOMCAT_VERSION} /opt/tomcat && \
rm /tmp/tomcat.tgz && \
rm -rf /opt/tomcat/webapps/examples && \
rm -rf /opt/tomcat/webapps/docs && \
rm -rf /opt/tomcat/webapps/ROOT

# Add admin/admin user
ADD tomcat-users.xml /opt/tomcat/conf/
run mkdir -p /opt/tomcat/conf/Catalina/localhost
ADD manager.xml /opt/tomcat/conf/Catalina/localhost

# Add demo employee data
RUN mkdir -p /opt/sql
COPY sql/employees.zip /opt/sql/
COPY sql/target.sql /opt/sql/

VOLUME "/opt/iiq"

RUN mkdir /opt/tomcat/webapps/ROOT
COPY index.html /opt/tomcat/webapps/ROOT

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CATALINA_HOME /opt/tomcat
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

# Launch IIQ
CMD ["/usr/bin/supervisord"]


# Old CMDs for reference
#CMD ["/entrypoint.sh", "run"]
#CMD ["/opt/tomcat/bin/catalina.sh", "run"]
