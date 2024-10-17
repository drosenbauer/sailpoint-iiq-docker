#!/bin/bash

source bin/include/utils.sh

COMPOSE_PATH=$(which docker-compose)

if [[ ! -z "$(echo "$COMPOSE_PATH" | grep "not found")" ]]; then
	redecho "Cannot find the docker-compose command"
	exit 5
fi

greenecho " => Checking for a running instance of sailpoint-iiq in Docker..."

OUTPUT=`docker-compose ps | grep 'iiq'`

if [[ ! -z "${OUTPUT}" ]]; then
        redecho "The IIQ Docker stack appears to be already running. Use the 'stop.sh' script to stop it first."
        exit 11
fi

greenecho " => Looks clear!"

docker-compose up -d
