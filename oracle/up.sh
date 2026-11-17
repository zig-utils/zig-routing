#!/usr/bin/env bash
# oracle/up.sh <dataset> [port]: serve a built dataset with valhalla_service on localhost.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: up.sh <dataset> [port]}"
port="${2:-8102}"
dir="$ORACLE_DATA/$name"
[ -f "$dir/tiles.tar" ] || "$ORACLE_DIR/build.sh" "$name"
docker rm -f "zr-oracle-$name" >/dev/null 2>&1 || true
docker run -d --platform "$ORACLE_PLATFORM" --name "zr-oracle-$name" -p "127.0.0.1:$port:8002" -v "$dir:/data:ro" "$ORACLE_IMAGE" \
  valhalla_service /data/valhalla.json 2 >/dev/null
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$port/status" >/dev/null && { echo "oracle: $name on http://127.0.0.1:$port"; exit 0; }
  sleep 0.5
done
docker logs "zr-oracle-$name" | tail -20
die "service did not come up"
