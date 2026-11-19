#!/usr/bin/env bash
# Fuzz each target for a fixed time; exit 1 if any target crashed.
#
#   scripts/fuzz.sh                 every target, 600 s each
#   scripts/fuzz.sh -s 60 lz4 http  the named targets, 60 s each
#
# Crashing inputs are copied to fuzz-crashers/<target>-<time>.bin with the log beside them.
# Turn one into a regression test with `replayStream` in test/fuzz/regressions.zig.
#
# Why not `zig build fuzz --fuzz` with `timeout`: open-ended fuzzing needs the web UI on
# the pinned toolchain, and `zig build` exits 0 even when a fuzz test crashes. So each
# target runs with a run limit far beyond what fits in the time, is stopped when the time
# is up, and a crash is detected from the saved input and the log, not the exit status.
set -uo pipefail

seconds=600
if [ "${1:-}" = "-s" ]; then seconds="$2"; shift 2; fi
targets=("$@")
[ ${#targets[@]} -eq 0 ] && targets=(request http polyline lz4 dem protobuf config osm-pbf node-store)

ZIG="${ZIG:-zig}"
if ! command -v "$ZIG" >/dev/null 2>&1 && [ -x "$HOME/.local/share/zig-0.17-master/zig" ]; then
  ZIG="$HOME/.local/share/zig-0.17-master/zig"
fi
cd "$(dirname "$0")/.."
mkdir -p fuzz-crashers

kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
}

# Build once so the time limit is spent fuzzing, not compiling.
"$ZIG" build fuzz >/dev/null || { echo "fuzz: seed replay failed"; exit 1; }

failed=0
for t in "${targets[@]}"; do
  log=$(mktemp)
  stopped="$log.stopped"
  rm -f .zig-cache/f/crash "$stopped"
  "$ZIG" build fuzz -Dfuzz-target="$t" --fuzz=100G >"$log" 2>&1 &
  pid=$!
  ( sleep "$seconds"; touch "$stopped"; kill_tree "$pid" ) &
  watcher=$!
  wait "$pid" 2>/dev/null
  kill_tree "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null

  if [ -f .zig-cache/f/crash ] || grep -qE 'terminated with signal|panic:|error: test .* failed' "$log"; then
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    [ -f .zig-cache/f/crash ] && cp .zig-cache/f/crash "fuzz-crashers/$t-$stamp.bin"
    cp "$log" "fuzz-crashers/$t-$stamp.log"
    echo "fuzz $t: CRASH (fuzz-crashers/$t-$stamp.*)"
    grep -E 'panic:|terminated with signal|error:' "$log" | head -5
    failed=1
  elif [ ! -f "$stopped" ]; then
    # The fuzzer must still be running when the time is up; an early exit without a crash
    # means it never fuzzed (unsupported platform, build failure), which is not a clean run.
    echo "fuzz $t: exited before ${seconds}s without fuzzing:"
    tail -20 "$log"
    failed=1
  else
    echo "fuzz $t: clean for ${seconds}s"
  fi
  rm -f "$log" "$stopped"
done
exit "$failed"
