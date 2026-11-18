#!/usr/bin/env bash
# oracle/bench-vm.sh <dataset> <corpus> [label]
#
# Valhalla against zr, both native arm64 inside the Docker VM, on one network, with the zr
# bench client in a third container: no emulation and no port forwarding in the numbers.
# Each server gets the same worker count; the client runs at 1 connection and at as many
# connections as the VM has CPUs.
#
#   oracle/bench-vm.sh liechtenstein bench/corpora/height.liechtenstein.tsv
#   ZR_ELEVATION=pack oracle/bench-vm.sh utrecht bench/corpora/height.utrecht.tsv
#
# ZR_ELEVATION=tiles (default) serves the same .hgt.gz files Valhalla reads; =pack packs them
# first with zr dem pack. Results go to bench/results/vm-<dataset>-<label>/.
source "$(dirname "$0")/lib.sh"
name="${1:?usage: bench-vm.sh <dataset> <corpus> [label]}"
corpus="${2:?usage: bench-vm.sh <dataset> <corpus> [label]}"
label="${3:-$(git -C "$ORACLE_DIR/.." rev-parse --short HEAD)}"
repo="$(cd "$ORACLE_DIR/.." && pwd)"
dir="$ORACLE_DATA/$name"
[ -f "$dir/tiles.tar" ] || "$ORACLE_DIR/build.sh" "$name"
[ -f "$corpus" ] || die "no corpus $corpus (bun tools/corpus/generate.ts)"
platform=linux/arm64
cpus=$(docker info --format '{{.NCPU}}')
workers=$(( cpus > 2 ? cpus - 2 : 1 ))   # leave the client two CPUs
duration="${DURATION:-10s}"
out="$repo/bench/results/vm-$name-$label"
mkdir -p "$out"

ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null 2>&1 || ZIG="$HOME/.local/share/zig-0.17-master/zig"
(cd "$repo" && "$ZIG" build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast --prefix zig-out-linux-arm) || die "zr build failed"
bin="$repo/zig-out-linux-arm/bin"

docker network create zrbench >/dev/null 2>&1 || true
cleanup() { docker rm -f zrb-valhalla zrb-zr >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

elevation=/data/elevation
if [ "${ZR_ELEVATION:-tiles}" = pack ]; then
  docker run --rm --platform "$platform" -v "$bin:/zr:ro" -v "$dir:/data:ro" -v "$out:/out" "$ORACLE_IMAGE" \
    /zr/zr dem pack /data/elevation /out/elevation.zdem >/dev/null || die "zr dem pack failed"
  elevation=/out/elevation.zdem
fi

docker run -d --platform "$platform" --name zrb-valhalla --network zrbench -v "$dir:/data:ro" "$ORACLE_IMAGE" \
  valhalla_service /data/valhalla.json "$workers" >/dev/null
docker run -d --platform "$platform" --name zrb-zr --network zrbench -v "$bin:/zr:ro" -v "$dir:/data:ro" -v "$out:/out:ro" "$ORACLE_IMAGE" \
  /zr/zr serve --port 8002 --threads "$workers" --elevation "$elevation" >/dev/null
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
va="http://$(ip zrb-valhalla):8002"
zr="http://$(ip zrb-zr):8002"

client() {
  docker run --rm --platform "$platform" --network zrbench -v "$bin:/zr:ro" -v "$repo/$(dirname "$corpus"):/corpus:ro" -v "$out:/out" "$ORACLE_IMAGE" \
    /zr/zr "$@"
}
for _ in $(seq 1 60); do
  client bench "$va" --corpus "/corpus/$(basename "$corpus")" --requests 1 --warmup 0 >/dev/null 2>&1 &&
    client bench "$zr" --corpus "/corpus/$(basename "$corpus")" --requests 1 --warmup 0 >/dev/null 2>&1 && break
  sleep 1
done

for conns in 1 "$cpus"; do
  for target in valhalla zr; do
    url=$va; [ "$target" = zr ] && url=$zr
    client bench "$url" --corpus "/corpus/$(basename "$corpus")" --connections "$conns" --threads "$(( conns < 2 ? 1 : 2 ))" \
      --duration "$duration" --warmup 2s --dataset "$name" --label "$target-c$conns" --out "/out/$target-c$conns.json" >/dev/null
  done
  echo "== $name, $(basename "$corpus"), $conns connection(s), $workers workers each, $cpus vCPUs"
  client bench --compare "/out/valhalla-c$conns.json" "/out/zr-c$conns.json"
done
# The round-trip floor: /status at one connection. Whatever a request costs beyond this is
# the server's work; at one connection the floor bounds any speedup ratio.
printf '/status\n' > "$out/status.tsv"
for target in valhalla zr; do
  url=$va; [ "$target" = zr ] && url=$zr
  docker run --rm --platform "$platform" --network zrbench -v "$bin:/zr:ro" -v "$out:/out" "$ORACLE_IMAGE" \
    /zr/zr bench "$url" --corpus /out/status.tsv --connections 1 --threads 1 --duration 5s --warmup 1s \
    --label "$target-status" --out "/out/$target-status.json" >/dev/null
done
echo "== round-trip floor: /status, 1 connection"
client bench --compare "/out/valhalla-status.json" "/out/zr-status.json" | sed -n '1,2p;4,6p'
echo "results in ${out#$repo/}"
