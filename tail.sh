#!/bin/bash

if [[ -e build/.composefile ]]; then
	FILE=`cat build/.composefile`
else
	FILE=docker-compose.yml
fi

docker-compose -p iiq -f $FILE logs -f "$@"
