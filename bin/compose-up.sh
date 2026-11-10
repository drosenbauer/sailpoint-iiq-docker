#!/bin/bash
# Starts the stack with the given number of IIQ nodes (default 1)

cd "$(dirname "$0")/.." || exit 1

docker compose up -d --scale iiq="${1:-1}"
