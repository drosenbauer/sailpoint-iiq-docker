#!/bin/bash

cd "$(dirname "$0")" || exit 1
source bin/include/utils.sh

if ! docker compose version > /dev/null 2>&1; then
	redecho "Cannot find the 'docker compose' command"
	exit 5
fi

greenecho " => Checking for a running instance of sailpoint-iiq in Docker..."

if [[ -n "$(docker compose ps -q 2> /dev/null)" ]]; then
	redecho "The IIQ Docker stack appears to be already running. Use 'bin/stop.sh' to stop it first."
	exit 11
fi

greenecho " => Looks clear!"

docker compose up -d
