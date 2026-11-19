#!/usr/bin/env bash
# Capture real call stacks from a running service or a benchmark command.
set -euo pipefail

usage() {
  echo 'usage: flamegraph.sh OUT.{svg,folded} --pid PID [SECONDS]' >&2
  echo '       flamegraph.sh OUT.{svg,folded} -- COMMAND [ARGS...]' >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
out="$1"
mode="$2"
shift 2
case "$out" in *.svg|*.folded) ;; *) usage ;; esac
case "$mode" in
  --pid)
    [ "$#" -le 2 ] || usage
    pid="$1"
    seconds="${2:-10}"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$seconds" =~ ^[1-9][0-9]*$ ]] || usage
    ;;
  --) ;;
  *) usage ;;
esac
command -v bun >/dev/null || { echo 'flamegraph.sh requires Bun to render stacks' >&2; exit 1; }

repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
child=
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$(uname -s)" in
  Linux)
    command -v perf >/dev/null || { echo 'flamegraph.sh requires Linux perf' >&2; exit 1; }
    record=(perf record -q -e cpu-clock:u -F 99 --call-graph dwarf -o "$tmp/perf.data")
    if [ "$mode" = --pid ]; then
      "${record[@]}" -p "$pid" -- sleep "$seconds"
    else
      "${record[@]}" -- "$@"
    fi
    perf script --no-inline -i "$tmp/perf.data" -F comm,pid,tid,time,event,ip,sym,dso > "$tmp/profile.txt"
    bun "$repo/tools/flamegraph/sample-to-svg.ts" "$tmp/profile.txt" "$out" --perf
    ;;
  Darwin)
    if [ "$mode" = --pid ]; then
      sample "$pid" "$seconds" -file "$tmp/profile.txt"
    else
      "$@" &
      child=$!
      sample "$child" 10 -file "$tmp/profile.txt"
      wait "$child"
      child=
    fi
    bun "$repo/tools/flamegraph/sample-to-svg.ts" "$tmp/profile.txt" "$out"
    ;;
  *)
    echo 'flamegraph.sh supports Linux and macOS' >&2
    exit 1
    ;;
esac
