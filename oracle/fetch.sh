#!/usr/bin/env bash
# oracle/fetch.sh <dataset>: download the dataset's extract and elevation tiles, checksum-verified.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: fetch.sh <dataset>}"
IFS=$'\t' read -r _ pbf_url pbf_sha tiles <<<"$(dataset_row "$name")"
dir="$ORACLE_DATA/$name"
mkdir -p "$dir/elevation"
fetch_checked "$pbf_url" "$dir/extract.osm.pbf" "$pbf_sha"
IFS=',' read -ra entries <<<"$tiles"
for entry in "${entries[@]}"; do
  tile="${entry%%=*}"
  sum="${entry#*=}"
  sub="${tile:0:3}"
  mkdir -p "$dir/elevation/$sub"
  fetch_checked "$ELEVATION_URL/$sub/$tile" "$dir/elevation/$sub/$tile" "$sum"
done
echo "oracle: fetched $name into $dir"
