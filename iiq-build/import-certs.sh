#!/bin/bash

################
# This script trusts any certs in the 'certs' directory (put there by the
# Dockerfile build). The certificate alias will be the base filename of the
# certificate file.

TRUSTSTORE="/opt/java/openjdk/lib/security/cacerts"

if [ "$(ls /opt/iiq/certs)" ]; then
    for cert in /opt/iiq/certs/*
    do
        if [ ! -e ${TRUSTSTORE} ]; then
          # This would happen if the version of Java changed, which seems unlikely...
          echo "ERROR: The Java cacerts file at ${TRUSTSTORE} does not appear to exist??"
          echo "Output of 'which java': $(which java)"
          echo "Output of 'java -version': "
          java -version
        else
          ALIAS=`basename $cert`
          echo "Importing certificate $cert to Java trust store as $ALIAS"
          keytool -import -trustcacerts -alias "$ALIAS" -file "$cert" -keystore /opt/java/openjdk/lib/security/cacerts -storepass changeit -noprompt
        fi
    done
else
	echo "No certificates to import"
fi
