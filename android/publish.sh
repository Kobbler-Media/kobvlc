#!/usr/bin/env bash
# Publishes the AAR android/build.sh laid out under work/maven as a GitHub release, which is
# what kobapp resolves from (an Ivy layout, readable from anywhere, CI included).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
ARTIFACT_DIR="${GROUP//.//}/$ARTIFACT"

[ -f "$WORK/maven/$ARTIFACT_DIR/$VERSION/$ARTIFACT-$VERSION.aar" ] ||
  { echo "nothing built for $VERSION; run android/build.sh first" >&2; exit 1; }

OUT="$WORK/maven/$ARTIFACT_DIR/$VERSION"
TAG="v$VERSION"
[ -f "$ROOT/local.env" ] && source "$ROOT/local.env"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token ${KOBVLC_GH_USER:+-u "$KOBVLC_GH_USER"})}"
gh release view "$TAG" -R Kobbler-Media/kobvlc >/dev/null 2>&1 ||
  gh release create "$TAG" -R Kobbler-Media/kobvlc --title "$TAG" --notes "$GROUP:$ARTIFACT:$VERSION"
gh release upload "$TAG" -R Kobbler-Media/kobvlc --clobber \
  "$OUT/$ARTIFACT-$VERSION.aar" "$OUT/$ARTIFACT-$VERSION.pom" "$OUT/ivy-$VERSION.xml"
echo "released $TAG"
