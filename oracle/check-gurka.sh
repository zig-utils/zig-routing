#!/usr/bin/env bash
# Verify that Valhalla reads the synthetic Gurka fixture and builds its graph.
source "$(dirname "$0")/lib.sh"
repo="$(cd "$ORACLE_DIR/.." && pwd)"
mkdir -p "$repo/bench/results"
work=$(mktemp -d "$repo/bench/results/gurka-oracle.XXXXXX")
image=$(oracle_compose gurka default 8102 config --images oracle)

cd "$repo"
zig build gurka-pbf -- "$work/fixture.osm.pbf"
docker run --rm --platform "$ORACLE_PLATFORM" -v "$work:/data" "$image" bash -ec '
  valhalla_build_config --mjolnir-tile-dir /data/tiles --mjolnir-tile-extract "" \
    --mjolnir-concurrency 1 > /data/valhalla.json
  valhalla_build_tiles -c /data/valhalla.json /data/fixture.osm.pbf
' > "$work/build.log" 2>&1 || die "Gurka tile build failed (log: $work/build.log)"
[[ -n $(find "$work/tiles" -type f -name '*.gph' -print -quit) ]] ||
  die "Gurka tile build did not produce graph tiles (log: $work/build.log)"
grep -q 'Finished with 3 routable ways' "$work/build.log" &&
  grep -q 'Finished with 1 simple turn restrictions' "$work/build.log" ||
  die "Gurka tile build did not read all ways and the restriction (log: $work/build.log)"
echo "oracle: Gurka PBF built graph tiles with 3 ways and 1 turn restriction ($work)"
