#!/usr/bin/env bash
# Runs the host-side tests of our Android VLC patches against the tree android/build.sh
# patched, so run that first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${KOBVLC_WORK:-$ROOT/work}"
VLC="$WORK/libvlcjni/vlc/modules"
SRC="$VLC/video_output/android"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cc -std=gnu11 -O2 -Wall -Wextra -Werror -I"$SRC" \
  "$ROOT/android/pacing-test.c" "$SRC/pacing.c" "$SRC/vsync_fit.c" -lm -o "$OUT/pacing-test"
"$OUT/pacing-test"

cc -std=gnu11 -O2 -Wall -Wextra -Werror -I"$ROOT/android/test-include" -I"$VLC/codec/omxil" \
  "$ROOT/android/aimage-reader-usage-test.c" -o "$OUT/aimage-reader-usage-test"
"$OUT/aimage-reader-usage-test"
