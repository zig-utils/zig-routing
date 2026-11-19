#!/usr/bin/env bash
# oracle/up.sh <dataset> [port] [default|unpruned]: serve a dataset on localhost.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: up.sh <dataset> [port] [default|unpruned]}"
port="${2:-8102}"
mode="${3:-default}"
case "$mode" in default|unpruned) ;; *) die "unknown oracle mode '$mode' (use default or unpruned)" ;; esac
ensure_built "$name"
oracle_compose "$name" "$mode" "$port" up -d --force-recreate oracle
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$port/status" >/dev/null &&
    { echo "oracle: $name ($mode) on http://127.0.0.1:$port"; exit 0; }
  sleep 0.5
done
oracle_compose "$name" "$mode" "$port" logs --tail=20 oracle
die "service did not come up"
