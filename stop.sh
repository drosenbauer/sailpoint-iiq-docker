#!/bin/bash

set -x

docker-compose -p iiq down "$@"
