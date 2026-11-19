#!/usr/bin/env bash
# oracle/down.sh <dataset> [default|unpruned]: stop a running oracle.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: down.sh <dataset> [default|unpruned]}"
dataset_row "$name" >/dev/null
oracle_compose "$name" "${2:-default}" 8102 down
