#!/usr/bin/env bash
# Runs inside the pinned Valhalla image, with the dataset mounted at /data.
set -euo pipefail

config_args=(
  --mjolnir-tile-dir /data/tiles
  --mjolnir-tile-extract /data/tiles.tar
  --mjolnir-concurrency 6
  --additional-data-elevation /data/elevation
  # Clipped fixture graphs can have disconnected components near their borders.
  --loki-use-connectivity false
)
valhalla_build_config "${config_args[@]}" > /data/valhalla.json
valhalla_build_config "${config_args[@]}" \
  --service-limits-max-distance-disable-hierarchy-culling 5000000 > /data/valhalla-unpruned.json
rm -rf /data/tiles /data/tiles.tar
valhalla_build_tiles -c /data/valhalla.json /data/extract.osm.pbf
valhalla_build_extract -c /data/valhalla.json -v
