#!/bin/bash

if [[ -e build/.composefile ]]; then
        FILE=`cat build/.composefile`
else
        FILE=docker-compose.yml
fi

set -x

docker-compose ps
