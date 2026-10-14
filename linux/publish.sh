#!/usr/bin/env bash
# Publishes the tarball linux/build.sh made as a GitHub release, which is where kobapp's
# desktop build resolves it from.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
ARCHIVE="$WORK/linux/libvlc-linux-x64-$DESKTOP_VERSION.tar.gz"

[ -f "$ARCHIVE" ] || { echo "nothing built for $DESKTOP_VERSION; run linux/build.sh first" >&2; exit 1; }

TAG="linux-v$DESKTOP_VERSION"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token -u kobbler-dev)}"
gh release view "$TAG" -R Kobbler-Media/kobvlc >/dev/null 2>&1 ||
  gh release create "$TAG" -R Kobbler-Media/kobvlc --title "$TAG" --notes "dev.kobbler.vlc:libvlc-linux-x64:$DESKTOP_VERSION"
gh release upload "$TAG" -R Kobbler-Media/kobvlc --clobber "$ARCHIVE"
echo "released $TAG"
