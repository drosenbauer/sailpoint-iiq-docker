#!/bin/bash

curl --output /dev/null --silent --head --fail http://localhost:8080/identityiq || exit 1

exit 0

