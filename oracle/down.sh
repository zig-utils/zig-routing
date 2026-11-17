#!/usr/bin/env bash
# oracle/down.sh <dataset>: stop a running oracle.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: down.sh <dataset>}"
docker rm -f "zr-oracle-$name" >/dev/null 2>&1 && echo "oracle: stopped $name" || echo "oracle: $name was not running"
