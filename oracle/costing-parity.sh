#!/usr/bin/env bash
# Gates A and B on the local graph of one pinned oracle extract.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

motor=
if [ "${1:-}" = "--motor" ] || [ "${1:-}" = "--truck" ] || [ "${1:-}" = "--motorcycle" ] || [ "${1:-}" = "--timed" ]; then
  motor="$1"
  shift
fi
[ "$#" -ge 2 ] && [ "$#" -le 3 ] ||
  die "usage: $0 [--motor|--truck|--motorcycle|--timed] DATASET REPORT.json [CASES_PER_PROFILE]"
dataset="$1"
report="$2"
default_cases=50000
if [ "$motor" = "--timed" ]; then
  default_cases=1
fi
cases="${3:-$default_cases}"
repo="$(cd "$ORACLE_DIR/.." && pwd)"
zr="${ZR:-$repo/zig-out/bin/zr}"
corpus="$repo/bench/corpora/route-foot-bike.$dataset.tsv"
if [ -n "$motor" ]; then
  corpus="$repo/bench/corpora/route-auto-10km.$dataset.tsv"
fi
[ -x "$zr" ] || die "build zr in ReleaseFast or set ZR"
[ -f "$corpus" ] || die "generate the route corpora before running the parity gate"
data="$ORACLE_DATA/$dataset"
image=$(awk '$1 == "image:" { print $2; exit }' "$ORACLE_DIR/compose.yaml")
mkdir -p "$repo/bench/results" "$(dirname "$report")"
work=$(mktemp -d "$repo/bench/results/costing-parity.XXXXXX")
echo "costing parity artifacts in $work" >&2

archive="$data/tiles.tar"
if [ "$motor" = "--timed" ]; then
  # Gate B needs the complete local graph on both sides. Building it flat
  # preserves connections that are represented by upper-level transitions.
  "$ORACLE_DIR/fetch.sh" "$dataset"
  docker run --rm --platform "$ORACLE_PLATFORM" \
    --mount "type=bind,source=$data,target=/data,readonly" \
    --mount "type=bind,source=$work,target=/work" \
    --entrypoint bash "$image" -euc '
      valhalla_build_config --mjolnir-tile-dir /work/tiles --mjolnir-tile-extract /work/tiles.tar \
        --mjolnir-concurrency 6 --mjolnir-hierarchy false --mjolnir-shortcuts false \
        --additional-data-elevation /data/elevation --loki-use-connectivity false > /work/valhalla.json
      valhalla_build_tiles -c /work/valhalla.json /data/extract.osm.pbf
      valhalla_build_extract -c /work/valhalla.json -v
    ' > "$work/build.log" 2>&1 || die "could not build the flat oracle graph. See $work/build.log"
  archive="$work/tiles.tar"
else
  ensure_built "$dataset"
  python3 - "$data" "$work" <<'PY'
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile

data, work = map(Path, sys.argv[1:])
# Give the routing oracle the same local tile set as the imported graph.
with tarfile.open(data / "tiles.tar") as archive:
    for member in archive:
        path = PurePosixPath(member.name)
        if (not member.isfile() or len(path.parts) < 2 or path.parts[0] != "2"
                or path.suffix != ".gph" or not path.stem.isdecimal()
                or not all(part.isdecimal() for part in path.parts[1:-1])):
            continue
        destination = work / "local" / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        with archive.extractfile(member) as src, destination.open("xb") as out:
            shutil.copyfileobj(src, out)
config = json.loads((data / "valhalla.json").read_text())
config["mjolnir"].update(tile_dir="/work/local", tile_extract="")
(work / "valhalla.json").write_text(json.dumps(config))
PY
fi

"$zr" import-valhalla "$archive" --output "$work/bundle"
uuid=$("$zr" inspect "$work/bundle" --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["dataset_uuid"])')
python3 "$ORACLE_DIR/costing-profiles.py" "$corpus" ${motor:+"$motor"} > "$work/profiles.jsonl"
docker run --rm --platform "$ORACLE_PLATFORM" \
  --mount "type=bind,source=$data,target=/data,readonly" \
  --mount "type=bind,source=$work,target=/work" \
  --mount "type=bind,source=$ORACLE_DIR/costing-reference.cc,target=/costing-reference.cc,readonly" \
  --entrypoint bash "$image" -euc '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      g++ libboost-dev libprotobuf-dev rapidjson-dev zlib1g-dev
    g++ -std=c++20 -O2 -Wno-psabi -I/usr/local/include/valhalla/third_party \
      /costing-reference.cc -o /work/reference -lvalhalla -lprotobuf-lite -lprime_server -lz \
      -l:libcurl.so.4 -l:liblz4.so.1 -l:libtiff.so.6 -l:libgeotiff.so.5 -pthread
    /work/reference /work/valhalla.json /work/profiles.jsonl "$1" "$2" /work/costs.bin
  ' costing-reference "$cases" "$uuid" > "$work/oracle.log" 2>&1 ||
  die "could not generate the oracle reference. See $work/oracle.log"

if [ "$motor" = "--timed" ]; then
  minimum=$(python3 -c 'import json,sys; print(sum(len(json.loads(line)["paths"]) for line in sys.stdin))' < "$work/profiles.jsonl")
  (
    cd "$repo"
    "${ZIG:-zig}" build motor-costing-parity -Doptimize=ReleaseFast -- "$work/bundle" "$work/costs.bin" --timed "$minimum"
  ) > "$report" 2> "$work/failures.log" ||
    die "timed route gate failed. See $report and $work/failures.log"
elif [ -n "$motor" ]; then
  (
    cd "$repo"
    "${ZIG:-zig}" build motor-costing-parity -Doptimize=ReleaseFast -- "$work/bundle" "$work/costs.bin" "$motor"
  ) > "$report" 2> "$work/failures.log" ||
    die "costing gate failed. See $report and $work/failures.log"
else
  "$zr" parity costing "$work/bundle" "$work/costs.bin" --out "$report" 2> "$work/failures.log" ||
    die "costing gate failed. See $report and $work/failures.log"
fi
