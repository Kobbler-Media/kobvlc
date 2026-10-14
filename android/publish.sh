#!/usr/bin/env bash
# Publishes the AAR android/build.sh laid out under work/maven: as a GitHub release, which is
# what kobapp resolves from (an Ivy layout, readable from anywhere, CI included), and to
# the LAN Maven host, which keeps only the two newest versions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
ARTIFACT_DIR="${GROUP//.//}/$ARTIFACT"

[ -f "$WORK/maven/$ARTIFACT_DIR/$VERSION/$ARTIFACT-$VERSION.aar" ] ||
  { echo "nothing built for $VERSION; run android/build.sh first" >&2; exit 1; }

ssh "$MAVEN_HOST" "mkdir -p '$MAVEN_DIR/$ARTIFACT_DIR'"
rsync -a "$WORK/maven/$ARTIFACT_DIR/$VERSION" "$MAVEN_HOST:$MAVEN_DIR/$ARTIFACT_DIR/"

ssh "$MAVEN_HOST" "cd '$MAVEN_DIR/$ARTIFACT_DIR' && ls -1t | tail -n +3 | xargs -r rm -rf && ls -1t"

curl -sfI "$MAVEN_URL/$ARTIFACT_DIR/$VERSION/$ARTIFACT-$VERSION.pom" >/dev/null &&
  echo "published $GROUP:$ARTIFACT:$VERSION to $MAVEN_URL"

OUT="$WORK/maven/$ARTIFACT_DIR/$VERSION"
TAG="v$VERSION"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token -u kobbler-dev)}"
gh release view "$TAG" -R Kobbler-Media/kobvlc >/dev/null 2>&1 ||
  gh release create "$TAG" -R Kobbler-Media/kobvlc --title "$TAG" --notes "$GROUP:$ARTIFACT:$VERSION"
gh release upload "$TAG" -R Kobbler-Media/kobvlc --clobber \
  "$OUT/$ARTIFACT-$VERSION.aar" "$OUT/$ARTIFACT-$VERSION.pom" "$OUT/ivy-$VERSION.xml"
echo "released $TAG"
