#!/usr/bin/env bash
# Copies what android/build.sh laid out under work/maven to the Maven host, then keeps
# only the two newest versions there: the one being published and the one before it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
ARTIFACT_DIR="${GROUP//.//}/$ARTIFACT"

[ -f "$WORK/maven/$ARTIFACT_DIR/$VERSION/$ARTIFACT-$VERSION.aar" ] ||
  { echo "nothing built for $VERSION; run android/build.sh first" >&2; exit 1; }

rsync -a "$WORK/maven/$ARTIFACT_DIR/$VERSION" "$MAVEN_HOST:$MAVEN_DIR/$ARTIFACT_DIR/"

ssh "$MAVEN_HOST" "cd '$MAVEN_DIR/$ARTIFACT_DIR' && ls -1t | tail -n +3 | xargs -r rm -rf && ls -1t"

curl -sfI "$MAVEN_URL/$ARTIFACT_DIR/$VERSION/$ARTIFACT-$VERSION.pom" >/dev/null &&
  echo "published $GROUP:$ARTIFACT:$VERSION to $MAVEN_URL"
