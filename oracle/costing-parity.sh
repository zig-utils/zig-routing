#!/usr/bin/env bash
# Gates A and B on the local graph of one pinned oracle extract.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

motor=
case "${1:-}" in
--motor|--truck|--motorcycle|--timed|--access)
  motor="$1"
  shift;;
esac
[ "$#" -ge 2 ] && [ "$#" -le 3 ] ||
  die "usage: $0 [--motor|--truck|--motorcycle|--timed|--access] DATASET REPORT.json [CASES_PER_PROFILE]"
dataset="$1"
report="$2"
default_cases=50000
if [ "$motor" = "--timed" ] || [ "$motor" = "--access" ]; then
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
if [ "$motor" = "--access" ]; then
  [ "$dataset" = "access-regions" ] || die "use the access-regions fixture with --access"
else
  [ -f "$corpus" ] || die "generate the route corpora before running the parity gate"
fi
data="$ORACLE_DATA/$dataset"
image=$(awk '$1 == "image:" { print $2; exit }' "$ORACLE_DIR/compose.yaml")
mkdir -p "$repo/bench/results" "$(dirname "$report")"
work=$(mktemp -d "$repo/bench/results/costing-parity.XXXXXX")
echo "costing parity artifacts in $work" >&2

archive="$data/tiles.tar"
if [ "$motor" = "--timed" ] || [ "$motor" = "--access" ]; then
  # Gate B needs the complete local graph on both sides. Building it flat
  # preserves connections that are represented by upper-level transitions.
  if [ "$motor" = "--access" ]; then
    (
      cd "$repo"
      "${ZIG:-zig}" build gurka-pbf -Doptimize=ReleaseFast -- "$work/access-regions.osm.pbf" access-regions "$work/profiles.jsonl"
    )
    data="$work"
    pbf=access-regions.osm.pbf
  else
    "$ORACLE_DIR/fetch.sh" "$dataset"
    pbf=extract.osm.pbf
  fi
  docker run --rm --platform "$ORACLE_PLATFORM" \
    --mount "type=bind,source=$data,target=/data,readonly" \
    --mount "type=bind,source=$work,target=/work" \
    --entrypoint bash "$image" -euc '
      pbf="$1"
      args=(--mjolnir-tile-dir /work/tiles --mjolnir-tile-extract /work/tiles.tar \
        --mjolnir-concurrency 6 --mjolnir-hierarchy false --mjolnir-shortcuts false \
        --loki-use-connectivity false --service-limits-max-distance-disable-hierarchy-culling 5000000)
      if [ "$pbf" = extract.osm.pbf ]; then args+=(--additional-data-elevation /data/elevation); fi
      valhalla_build_config "${args[@]}" > /work/valhalla.json
      valhalla_build_tiles -c /work/valhalla.json "/data/$pbf"
      valhalla_build_extract -c /work/valhalla.json -v
    ' build-flat "$pbf" > "$work/build.log" 2>&1 ||
    die "could not build the flat oracle graph. See $work/build.log"
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
if [ "$motor" = "--access" ]; then
  python3 - "$work/profiles.jsonl" > "$work/profiles-unpruned.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as profiles:
    for line in profiles:
        profile = json.loads(line)
        for request in profile["paths"]:
            request["costing_options"]["auto"]["disable_hierarchy_pruning"] = True
        print(json.dumps(profile, separators=(",", ":")))
PY
else
  python3 "$ORACLE_DIR/costing-profiles.py" "$corpus" ${motor:+"$motor"} > "$work/profiles.jsonl"
fi
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
    if [ "$3" = "--access" ]; then
      /work/reference /work/valhalla.json /work/profiles-unpruned.jsonl "$1" "$2" /work/unpruned.bin
    fi
  ' costing-reference "$cases" "$uuid" "$motor" > "$work/oracle.log" 2>&1 ||
  die "could not generate the oracle reference. See $work/oracle.log"

if [ "$motor" = "--timed" ] || [ "$motor" = "--access" ]; then
  minimum=$(python3 -c 'import json,sys; print(sum(len(json.loads(line)["paths"]) for line in sys.stdin))' < "$work/profiles.jsonl")
  default_report="$report"
  if [ "$motor" = "--access" ]; then default_report="$work/default.json"; fi
  (
    cd "$repo"
    "${ZIG:-zig}" build motor-costing-parity -Doptimize=ReleaseFast -- "$work/bundle" "$work/costs.bin" "$motor" "$minimum"
  ) > "$default_report" 2> "$work/default-diagnostics.log" ||
    die "route gate failed. See $default_report and $work/default-diagnostics.log"
  if [ "$motor" = "--access" ]; then
    (
      cd "$repo"
      "${ZIG:-zig}" build motor-costing-parity -Doptimize=ReleaseFast -- "$work/bundle" "$work/unpruned.bin" --access "$minimum"
    ) > "$work/unpruned.json" 2> "$work/unpruned-diagnostics.log" ||
      die "route gate failed. See $work/unpruned.json and $work/unpruned-diagnostics.log"
    python3 - "$work" > "$report" <<'PY'
import json
from pathlib import Path
import sys

work = Path(sys.argv[1])
print(json.dumps({mode: json.loads((work / (mode + ".json")).read_text()) for mode in ("default", "unpruned")}))
PY
  fi
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
