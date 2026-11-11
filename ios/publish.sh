#!/usr/bin/env bash
# Publishes the archive ios/build.sh made as a GitHub release, which is where kobapp's
# iOS build resolves it from.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
ARCHIVE="$WORK/ios/libvlc-ios-$VERSION.tar.gz"

[ -f "$ARCHIVE" ] || { echo "nothing built for $VERSION; run ios/build.sh first" >&2; exit 1; }

TAG="ios-v$VERSION"
[ -f "$ROOT/local.env" ] && source "$ROOT/local.env"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token ${KOBVLC_GH_USER:+-u "$KOBVLC_GH_USER"})}"
gh release view "$TAG" -R Kobbler-Media/kobvlc >/dev/null 2>&1 ||
  gh release create "$TAG" -R Kobbler-Media/kobvlc --title "$TAG" --notes "dev.kobbler.vlc:libvlc-ios:$VERSION"
gh release upload "$TAG" -R Kobbler-Media/kobvlc --clobber "$ARCHIVE"
echo "released $TAG"
