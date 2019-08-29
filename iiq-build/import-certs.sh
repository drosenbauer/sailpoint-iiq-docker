#!/bin/bash

if [ "$(ls /opt/iiq/certs)" ]; then
    for cert in /opt/iiq/certs/*
    do
        ALIAS=`basename $cert`
        echo "Importing certificate $cert to Java trust store as $ALIAS"
        keytool -import -trustcacerts -alias "$ALIAS" -file "$cert" -keystore /usr/lib/jvm/java-8-openjdk-amd64/jre/lib/security/cacerts -storepass changeit -noprompt
    done
else
	echo "No certificates to import"
fi
