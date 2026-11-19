#!/usr/bin/env bash
# Regenerate checked-in tag records or compare them against a local zr build.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo="$(cd "$ORACLE_DIR/.." && pwd)"
zr="${ZR:-$repo/zig-out/bin/zr}"
goldens="$ORACLE_DIR/tag-goldens"

pbf_for() {
  local name="$1" row url hash path
  row=$(dataset_row "$name")
  IFS=$'\t' read -r _ url hash _ <<< "$row"
  path="$ORACLE_DATA/$name/extract.osm.pbf"
  mkdir -p "$(dirname "$path")"
  fetch_checked "$url" "$path" "$hash"
  echo "$path"
}

generate() (
  local source="$1" input="$2" output="$3" image work pbf
  case "$input" in
    liechtenstein|utrecht) pbf=$(pbf_for "$input") ;;
    *) pbf="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")" ;;
  esac
  [ -f "$pbf" ] || die "missing PBF '$pbf'"
  local revision=5c7f918e61306521d79cc4496d40c19c5305fa4b
  [ "$(git -C "$source" rev-parse HEAD)" = "$revision" ] || die "use Valhalla source at $revision"
  git -C "$source" diff --quiet HEAD -- lua/graph.lua valhalla || die "use unmodified Lua and headers"

  image=$(awk '$1 == "image:" { print $2; exit }' "$ORACLE_DIR/compose.yaml")
  local scratch="${TAG_GOLDEN_WORK:-$repo/bench/results}"
  mkdir -p "$scratch" "$(dirname "$output")"
  work=$(mktemp -d "$(cd "$scratch" && pwd)/tag-goldens.XXXXXX")
  temporary=$(mktemp "${output%.gz}.XXXXXX")
  trap 'rm -f -- "$temporary"' EXIT
  echo "Valhalla intermediate files: $work" >&2

  "${CXX:-c++}" -std=c++20 -O2 -I "$source" "$ORACLE_DIR/tag-reference.cc" -o "$work/project"
  cp "$source/lua/graph.lua" "$work/graph.lua"
  docker run --rm --platform "$ORACLE_PLATFORM" \
    --mount "type=bind,source=$work,target=/work" \
    --mount "type=bind,source=$pbf,target=/input.osm.pbf,readonly" \
    --entrypoint bash "$image" -euc '
      valhalla_build_config --mjolnir-tile-dir /work/tiles --mjolnir-concurrency 4 \
        --mjolnir-include-construction true --mjolnir-include-driveways true \
        --mjolnir-include-platforms true --mjolnir-pedestrian-areas true \
        --mjolnir-data-processing-allow-alt-name true \
        --mjolnir-data-processing-infer-turn-channels false > /work/valhalla.json
      valhalla_build_tiles -c /work/valhalla.json --end parseways /input.osm.pbf
    '
  "$work/project" "$work/tiles/ways.bin" "$work/tiles/osmdata_unique_strings.bin" > "$work/ways.tsv"
  "$zr" tags dump --raw "$pbf" |
    docker run --rm -i --platform "$ORACLE_PLATFORM" \
      --mount "type=bind,source=$work,target=/work,readonly" \
      --mount "type=bind,source=$ORACLE_DIR/tag-oracle.py,target=/tag-oracle.py,readonly" \
      --entrypoint python3 "$image" /tag-oracle.py /work/graph.lua /work/ways.tsv |
    gzip -n > "$temporary"
  chmod 644 "$temporary"
  mv -- "$temporary" "$output"
  trap - EXIT
)

compare() {
  local name pbf status=0
  for name in "$@"; do
    pbf=$(pbf_for "$name")
    echo "Comparing $name"
    "$zr" tags dump "$pbf" |
      python3 "$ORACLE_DIR/tag-compare.py" "$goldens/$name.jsonl.gz" || status=1
  done
  return "$status"
}

[ -x "$zr" ] || die "build zr with zig build -Doptimize=ReleaseFast (or set ZR)"
case "${1:-}" in
  generate)
    [ "$#" -eq 4 ] || die "usage: $0 generate VALHALLA_SOURCE DATASET_OR_PBF OUTPUT.jsonl.gz"
    generate "$2" "$3" "$4"
    ;;
  compare)
    shift
    if [ "$#" -eq 0 ]; then set -- liechtenstein utrecht; fi
    compare "$@"
    ;;
  *) die "usage: $0 {generate VALHALLA_SOURCE DATASET_OR_PBF OUTPUT.jsonl.gz|compare [DATASET ...]}" ;;
esac
