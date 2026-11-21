#!/usr/bin/env bash
# oracle/fetch.sh <dataset>: download the dataset's extract and elevation tiles, checksum-verified.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: fetch.sh <dataset>}"
row=$(dataset_row "$name")
IFS=$'\t' read -r _ pbf_url pbf_sha tiles profile second_url second_sha <<<"$row"
dir="$ORACLE_DATA/$name"
case "${profile:-fixture}" in
  fixture) seconds=180 ;;
  production) seconds=14400 ;;
  *) die "unknown build profile '$profile'" ;;
esac
if [ -n "${second_url:-}" ] && [ -z "${second_sha:-}" ]; then die "missing secondary PBF checksum"; fi
dem=$(dataset_dem_list "$tiles")
mkdir -p "$dir/elevation"
fetch_checked "$pbf_url" "$dir/extract.osm.pbf" "$pbf_sha" "$seconds"
if [ -n "${second_url:-}" ]; then
  fetch_checked "$second_url" "$dir/extract-secondary.osm.pbf" "$second_sha" "$seconds"
fi
while read -r sum tile extra; do
  [[ "$tile" =~ ^[NS][0-9]{2}[EW][0-9]{3}\.hgt\.gz$ && -z "$extra" ]] || die "invalid elevation entry '$tile'"
  sub="${tile:0:3}"
  mkdir -p "$dir/elevation/$sub"
  fetch_checked "$ELEVATION_URL/$sub/$tile" "$dir/elevation/$sub/$tile" "$sum"
done <<<"$dem"
echo "oracle: fetched $name into $dir"
