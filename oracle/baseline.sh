#!/usr/bin/env bash
# Run the pinned Valhalla baseline for one prebuilt regional dataset on native Linux.
source "$(dirname "$0")/lib.sh"

[ "$#" -ge 2 ] || die "usage: baseline.sh <dataset> <output-directory> [--corpus FILE] [--connections N] [--minimum-requests N] [--warmup TIME]"
name="$1"
out="$2"
shift 2
selected_corpus=
selected_load=
warmup=2s
minimum_requests=1
if [ "$name" != us-dach ]; then minimum_requests=5000; fi
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for $1"
  case "$1" in
    --corpus) selected_corpus="$2" ;;
    --connections) selected_load="$2" ;;
    --minimum-requests) minimum_requests="$2" ;;
    --warmup) warmup="$2" ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done
[[ "$minimum_requests" =~ ^[1-9][0-9]*$ ]] || die "minimum requests must be positive"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "run on the native x86-64 Linux benchmark host"
repo="$(cd "$ORACLE_DIR/.." && pwd)"
zr="${ZR:-$repo/zig-out/bin/zr}"
[ -x "$zr" ] || die "build zr in ReleaseFast or set ZR to its executable"
case "$zr" in /*) ;; *) zr="$PWD/$zr" ;; esac
ORACLE_PLATFORM=linux/amd64
data="$ORACLE_DATA/$name"
key=$(build_key "$name")
[ -s "$data/tiles.tar" ] && [ -s "$data/valhalla.json" ] &&
  [ -f "$data/build.key" ] && [ "$(cat "$data/build.key")" = "$key" ] ||
  die "build the pinned $name dataset before running the benchmark"

manifest="$repo/bench/corpora/manifest.json"
corpora=$(jq -er --arg name "$name" --arg file "$selected_corpus" '
  .corpora[] | select(.dataset == $name and ($file == "" or .file == $file)) | [.file, .requests, .sha256] | @tsv
' "$manifest") || die "no regional corpora for $name"
while IFS=$'\t' read -r file requests checksum; do
  corpus="$repo/bench/corpora/$file"
  [ -f "$corpus" ] && [ "$(wc -l < "$corpus")" -eq "$requests" ] &&
    [ "$(sha256 "$corpus")" = "$checksum" ] || die "regenerate $file from its corpus manifest"
done <<< "$corpora"

# Keep the benchmark separate from any oracle already serving this dataset.
# Require a fresh results directory so interrupted measurements stay intact.
mkdir -p -- "$(dirname "$out")"
mkdir -- "$out"
out="$(cd "$out" && pwd)"
image=$(oracle_compose "$name" default 8102 config --images oracle)
cpus=$(nproc)
loads=(1)
[ "$cpus" -eq 1 ] || loads+=("$cpus")
if [ -n "$selected_load" ]; then
  [ "$selected_load" = 1 ] || [ "$selected_load" = "$cpus" ] || die "connections must be 1 or the CPU count"
  loads=("$selected_load")
fi
workers=6
container=
cleanup() { if [ -n "$container" ]; then docker stop "$container" >/dev/null; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Include container startup and polling through the first successful HTTP response.
now() { python3 -c 'from time import monotonic_ns; print(monotonic_ns())'; }
start=$(now)
container=$(docker run --detach --rm --platform "$ORACLE_PLATFORM" --publish 127.0.0.1::8002 \
  --volume "$data:/data:ro" "$image" valhalla_service /data/valhalla.json "$workers")
port=$(docker inspect --format '{{(index (index .NetworkSettings.Ports "8002/tcp") 0).HostPort}}' "$container")
url="http://127.0.0.1:$port"
status=
for _ in $(seq 1 240); do
  if status=$(curl --silent --fail --max-time 1 "$url/status"); then break; fi
  sleep 0.5
done
startup_ns=$(( $(now) - start ))
version=$(jq -er '.version' <<< "$status") || die "the oracle did not return /status"
[ "$version" = 3.9.3 ] || die "unexpected Valhalla version $version"

IFS=$'\t' read -r _ _ pbf elevation _ _ secondary_sha <<< "$(dataset_row "$name")"
elevation_sha=$(dataset_dem_list "$elevation" | sha256 /dev/stdin)
configuration_sha=$(sha256 "$data/valhalla.json")
memory=$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)
jq -n --arg dataset "$name" --arg image "$image" --arg build_key "$key" \
  --arg extract_sha256 "$pbf" --arg secondary_sha256 "${secondary_sha:-}" \
  --arg elevation_manifest_sha256 "$elevation_sha" --arg configuration_sha256 "$configuration_sha" \
  --arg kernel "$(uname -r)" --argjson cpus "$cpus" --argjson memory_bytes "$memory" \
  --argjson workers "$workers" --argjson startup_ns "$startup_ns" \
  '$ARGS.named' > "$out/run.json"

stable=true
cd "$repo"
while IFS=$'\t' read -r file requests checksum; do
  # Keep complete corpus cycles while giving small fixtures enough samples.
  replays=$(( (minimum_requests + requests - 1) / requests ))
  measured_requests=$(( replays * requests ))
  for connections in "${loads[@]}"; do
    prefix="$out/${file%.tsv}-c$connections"
    pair_stable=false
    for repeat in 1 2 3 4; do
      "$zr" bench "$url" --corpus "bench/corpora/$file" --requests "$measured_requests" --warmup "$warmup" \
        --threads 1 --connections "$connections" --dataset "$name" --commit "$version" --out "$prefix-$repeat.tmp"
      jq --arg sha256 "$checksum" 'del(.target) | .corpus.sha256 = $sha256' \
        "$prefix-$repeat.tmp" > "$prefix-$repeat.json"
      jq -e --argjson requests "$measured_requests" '
        .requests == $requests and .errors.transport == 0 and .errors.timeouts == 0 and .errors.unsent == 0
      ' "$prefix-$repeat.json" >/dev/null || die "incomplete replay for $file at $connections connections"
      rm -- "$prefix-$repeat.tmp"
      if [ "$repeat" -eq 1 ]; then continue; fi
      previous=$(( repeat - 1 ))
      if jq -es 'map(.latency_us.p50) | max <= (min * 1.05)' \
          "$prefix-$previous.json" "$prefix-$repeat.json" >/dev/null; then
        pair_stable=true
        if [ "$repeat" -gt 2 ]; then
          jq -n --argjson first "$previous" --argjson second "$repeat" '[$first, $second]' \
            > "$prefix-accepted.json"
        fi
        break
      fi
    done
    if ! $pair_stable; then
      echo "oracle: no consecutive p50 pair agreed within 5% for $file at $connections connections" >&2
      stable=false
    fi
  done
done <<< "$corpora"

rss=$(docker exec "$container" awk '/^VmRSS:/ {printf "%.0f", $2 * 1024}' /proc/1/status)
jq -n --argjson rss_bytes "$rss" --argjson p50_within_five_percent "$stable" \
  '$ARGS.named' > "$out/final.json"
$stable || die "p50 stability check failed, see $out"
