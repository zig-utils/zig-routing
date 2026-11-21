#!/usr/bin/env bash
# Runs inside the pinned Valhalla image, with the dataset mounted at /data.
set -euo pipefail

config_args=(
  --mjolnir-tile-dir /data/tiles
  --mjolnir-tile-extract /data/tiles.tar
  --mjolnir-concurrency 6
  --additional-data-elevation /data/elevation
)
pbf=(/data/extract.osm.pbf)
if [ -n "${ORACLE_SECOND_PBF:-}" ]; then pbf+=("$ORACLE_SECOND_PBF"); fi
profile="${ORACLE_BUILD_PROFILE:-fixture}"
case "$profile" in
  fixture)
    # Clipped fixture graphs can have disconnected components near their borders.
    config_args+=(--loki-use-connectivity false)
    ;;
  production)
    config_args+=(--mjolnir-admin /data/admin.sqlite --mjolnir-timezone /data/tz_world.sqlite)
    ;;
  *) echo "unknown build profile '$profile'" >&2; exit 1 ;;
esac
valhalla_build_config "${config_args[@]}" > /data/valhalla.json
valhalla_build_config "${config_args[@]}" \
  --service-limits-max-distance-disable-hierarchy-culling 5000000 > /data/valhalla-unpruned.json
rm -rf /data/tiles /data/tiles.tar
if [ "$profile" = production ]; then
  rm -f /data/admin.sqlite /data/tz_world.sqlite
  valhalla_build_admins -c /data/valhalla.json "${pbf[@]}"
  (
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT
    cd "$scratch"
    valhalla_build_timezones > /data/tz_world.sqlite
  )
  test -s /data/admin.sqlite
  test -s /data/tz_world.sqlite
fi
valhalla_build_tiles -c /data/valhalla.json "${pbf[@]}"
valhalla_build_extract -c /data/valhalla.json -v
