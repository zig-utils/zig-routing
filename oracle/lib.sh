#!/usr/bin/env bash
# Shared settings for the oracle scripts. Sourced, not run.
set -euo pipefail

# Valhalla 3.9.3, pinned by digest (multi-arch; arm64 and amd64).
ORACLE_IMAGE="ghcr.io/valhalla/valhalla@sha256:cf618ccafdead96829282acc81a70aa00947c2f28ddcf118f0194acf2fbc7e9d"
ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORACLE_DATA="${ORACLE_DATA:-$ORACLE_DIR/data}"
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
