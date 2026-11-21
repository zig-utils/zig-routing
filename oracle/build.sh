#!/usr/bin/env bash
# oracle/build.sh <dataset>: build Valhalla tiles (with elevation) for a fetched dataset.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: build.sh <dataset>}"
dir="$ORACLE_DATA/$name"
row=$(dataset_row "$name")
IFS=$'\t' read -r _ _ _ _ profile second_url _ <<<"$row"
second=
if [ -n "${second_url:-}" ]; then second=/data/extract-secondary.osm.pbf; fi
key=$(build_key "$name")
"$ORACLE_DIR/fetch.sh" "$name"
start=$(date +%s)
rm -f "$dir/build.key"
oracle_compose "$name" default 8102 run --rm -T \
  -e "ORACLE_BUILD_PROFILE=${profile:-fixture}" -e "ORACLE_SECOND_PBF=$second" build
[ -s "$dir/tiles.tar" ] || die "build did not produce a tile extract for '$name'"
printf '%s\n' "$key" > "$dir/build.key"
echo "oracle: built $name in $(( $(date +%s) - start ))s ($(du -sh "$dir" | cut -f1) on disk)"
