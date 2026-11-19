#!/usr/bin/env bash
# Shared settings for the oracle scripts. Sourced, not run.
set -euo pipefail

ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORACLE_DATA="${ORACLE_DATA:-$ORACLE_DIR/data}"
case "$ORACLE_DATA" in /*) ;; *) ORACLE_DATA="$PWD/$ORACLE_DATA" ;; esac
# x86-64 by default: production runs x86-64, and the arm64 build is compiled with
# fused multiply-add contraction (GCC aarch64 default), which changes last-bit
# floating point results. Override with ORACLE_PLATFORM=linux/arm64 if needed.
ORACLE_PLATFORM="${ORACLE_PLATFORM:-linux/amd64}"
ELEVATION_URL="https://elevation-tiles-prod.s3.amazonaws.com/skadi"

# Docker may come from pantry's global bin without being on PATH.
if ! command -v docker >/dev/null 2>&1 && [ -x "$HOME/.local/share/pantry/global/bin/docker" ]; then
  export PATH="$HOME/.local/share/pantry/global/bin:$PATH"
fi

die() { echo "oracle: $*" >&2; exit 1; }

oracle_compose() {
  local name="$1" mode="$2" port="$3" project config
  shift 3
  project="zr-oracle-$name"
  case "$mode" in
    default) config=valhalla.json ;;
    unpruned) config=valhalla-unpruned.json; project="$project-unpruned" ;;
    *) die "unknown oracle mode '$mode' (use default or unpruned)" ;;
  esac
  ORACLE_PLATFORM="$ORACLE_PLATFORM" ORACLE_DATASET_DIR="$ORACLE_DATA/$name" \
    ORACLE_PORT="$port" ORACLE_CONFIG="$config" \
    docker compose -f "$ORACLE_DIR/compose.yaml" -p "$project" "$@"
}

build_key() {
  {
    dataset_row "$1"
    echo "$ORACLE_PLATFORM"
    shasum -a 256 < "$ORACLE_DIR/compose.yaml"
    shasum -a 256 < "$ORACLE_DIR/build-tiles.sh"
  } | shasum -a 256 | cut -d' ' -f1
}

ensure_built() {
  local name="$1" dir="$ORACLE_DATA/$1" key
  key=$(build_key "$name") || die "cannot identify the build for '$name'"
  if [ -s "$dir/tiles.tar" ] && [ -s "$dir/valhalla.json" ] &&
     [ -s "$dir/valhalla-unpruned.json" ] && [ -f "$dir/build.key" ] &&
     [ "$(cat "$dir/build.key")" = "$key" ]; then return 0; fi
  "$ORACLE_DIR/build.sh" "$name"
}

dataset_row() {
  local name="$1"
  local row
  row=$(awk -F'\t' -v n="$name" '$1 == n' "$ORACLE_DIR/datasets.tsv")
  [ -n "$row" ] || die "unknown dataset '$name' (see datasets.tsv)"
  echo "$row"
}

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

fetch_checked() {
  local url="$1" dest="$2" want="$3"
  if [ -f "$dest" ] && [ "$(sha256 "$dest")" = "$want" ]; then return 0; fi
  curl -sSfL -o "$dest.part" "$url" || die "download failed: $url"
  local got
  got=$(sha256 "$dest.part")
  [ "$got" = "$want" ] || { rm -f "$dest.part"; die "checksum mismatch for $url: got $got"; }
  mv "$dest.part" "$dest"
}
