#!/usr/bin/env bash
# oracle/build.sh <dataset>: build Valhalla tiles (with elevation) for a fetched dataset.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: build.sh <dataset>}"
dir="$ORACLE_DATA/$name"
[ -f "$dir/extract.osm.pbf" ] || "$ORACLE_DIR/fetch.sh" "$name"
start=$(date +%s)
docker run --rm --platform "$ORACLE_PLATFORM" -v "$dir:/data" "$ORACLE_IMAGE" bash -euo pipefail -c '
  rm -rf /data/tiles /data/tiles.tar
  valhalla_build_config \
    --mjolnir-tile-dir /data/tiles \
    --mjolnir-tile-extract /data/tiles.tar \
    --additional-data-elevation /data/elevation \
    --loki-use-connectivity false \
    > /data/valhalla.json
  valhalla_build_tiles -c /data/valhalla.json /data/extract.osm.pbf
  valhalla_build_extract -c /data/valhalla.json -v
'
echo "oracle: built $name in $(( $(date +%s) - start ))s ($(du -sh "$dir" | cut -f1) on disk)"
