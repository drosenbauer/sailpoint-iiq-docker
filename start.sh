#!/bin/bash

greenecho " => Checking for a running instance of sailpoint-iiq in Docker..."

OUTPUT=`docker-compose ps | grep 'iiq'`

if [[ ! -z "${OUTPUT}" ]]; then
        redecho "The IIQ Docker stack appears to be already running. Use the 'stop.sh' script to stop it first."
        exit 11
fi

greenecho " => Looks clear!"

docker-compose up -d
