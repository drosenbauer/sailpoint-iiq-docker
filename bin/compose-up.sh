#!/bin/bash

if [[ ! -z $1 ]]; then
	SCALE=$1
else
	SCALE=1
fi

docker-compose up -d --scale iiq=$SCALE
