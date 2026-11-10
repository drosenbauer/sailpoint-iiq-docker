#!/bin/bash
# Follows container logs; pass service names to limit it, e.g. bin/tail.sh iiq

cd "$(dirname "$0")/.." || exit 1

docker compose logs --tail=20 -f "$@"
