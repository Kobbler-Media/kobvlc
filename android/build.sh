#!/usr/bin/env bash
# Builds the libvlc-all AAR: VideoLAN's libvlcjni at the pinned commit with patches/ on
# top, compiled in VideoLAN's own Android image against their prebuilt contribs, then
# laid out as a Maven repository under work/maven.
#
#   android/build.sh                 every ABI
#   android/build.sh arm64 arm       just those (an AAR for testing on those devices)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
JNI="$WORK/libvlcjni"
VLC="$JNI/vlc"
ABIS=("$@")
[ ${#ABIS[@]} -gt 0 ] || ABIS=(arm64 arm x86 x86_64)
JAVA_HOME="${KOBVLC_JAVA_HOME:-/usr/lib/jvm/java-21-openjdk}"
GIT_AS_BUILD=(git -c user.name=kobvlc -c user.email=kobvlc@build.invalid -c commit.gpgsign=false)

declare -A TRIPLETS=(
  [arm64]=aarch64-linux-android [arm]=arm-linux-androideabi
  [x86]=i686-linux-android [x86_64]=x86_64-linux-android
)

mkdir -p "$WORK"

# libvlcjni, reset to the pin with our patches applied. The VLC patches join its own
# series, after upstream's, so get-vlc applies the lot in order.
[ -d "$JNI/.git" ] || git clone -q "$LIBVLCJNI_URL" "$JNI"
git -C "$JNI" cat-file -e "$LIBVLCJNI_COMMIT" 2>/dev/null || git -C "$JNI" fetch -q origin
# A run that stopped on a patch that no longer applies leaves the series half applied.
git -C "$JNI" am --abort 2>/dev/null || true
git -C "$JNI" reset -q --hard "$LIBVLCJNI_COMMIT"
git -C "$JNI" clean -qfd -- libvlc/patches
"${GIT_AS_BUILD[@]}" -C "$JNI" am -q "$ROOT"/patches/libvlcjni/*.patch
for p in "$ROOT"/patches/vlc/*.patch; do
  cp "$p" "$JNI/libvlc/patches/kob-$(basename "$p")"
done

# VLC at the commit libvlcjni pins. An existing tree is reset rather than recloned, so
# only the files the patches touch are rebuilt.
VLC_HASH="$(sed -n 's/^VLC_TESTED_HASH=//p' "$JNI/buildsystem/get-vlc.sh")"
if [ -d "$VLC/.git" ]; then
  git -C "$VLC" cat-file -e "$VLC_HASH" 2>/dev/null || git -C "$VLC" fetch -q origin
  git -C "$VLC" am --abort 2>/dev/null || true
  git -C "$VLC" reset -q --hard "$VLC_HASH"
  "${GIT_AS_BUILD[@]}" -C "$VLC" am -q --message-id "$JNI"/libvlc/patches/*.patch
else
  (cd "$JNI" && ./buildsystem/get-vlc.sh)
fi

BUILD_IMAGE="$(sed -n 's/^ *image: *//p' "$JNI/buildsystem/gitlab/.gitlab-ci.yml" | head -n1)"
[ -n "$BUILD_IMAGE" ] || { echo "no build image in libvlcjni's CI file" >&2; exit 1; }

BLACKLIST_EXTRA="$(grep -vE '^\s*(#|$)' "$ROOT/modules-blacklist" | tr '\n' ' ')"

for abi in "${ABIS[@]}"; do
  triplet="${TRIPLETS[$abi]}"
  sha="$(cd "$VLC" && extras/ci/get-contrib-sha.sh "android-$abi")"
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -e VLC_PREBUILT_CONTRIBS_URL="https://artifacts.videolan.org/vlc/android-$abi/vlc-contrib-$triplet-$sha.tar.bz2" \
    -e VLC_MODULE_BLACKLIST_EXTRA="$BLACKLIST_EXTRA" \
    -v "$JNI:/src" -w /src "$BUILD_IMAGE" \
    ./buildsystem/compile-libvlc.sh -a "$abi" --release --with-prebuilt-contribs
done

# The image's SDK lacks the platform libvlcjni compiles against and cannot be written to,
# so the AAR is packaged on the host. AGP's jlink step fails under JDK 22+.
JAVA_HOME="$JAVA_HOME" "$ROOT/gradlew" -q -p "$JNI" :libvlc:assembleRelease

OUT="$WORK/maven/${GROUP//.//}/$ARTIFACT/$VERSION"
mkdir -p "$OUT"
cp "$JNI/libvlc/build/outputs/aar/libvlc-release.aar" "$OUT/$ARTIFACT-$VERSION.aar"
sed -e "s/@GROUP@/$GROUP/" -e "s/@ARTIFACT@/$ARTIFACT/" -e "s/@VERSION@/$VERSION/" \
  "$ROOT/android/pom.xml.in" > "$OUT/$ARTIFACT-$VERSION.pom"
sed -e "s/@GROUP@/$GROUP/" -e "s/@ARTIFACT@/$ARTIFACT/" -e "s/@VERSION@/$VERSION/" \
  "$ROOT/android/ivy.xml.in" > "$OUT/ivy-$VERSION.xml"
(cd "$OUT" && for f in *.aar *.pom; do sha1sum "$f" | cut -d' ' -f1 > "$f.sha1"; done)

echo "built $GROUP:$ARTIFACT:$VERSION ($(du -h "$OUT/$ARTIFACT-$VERSION.aar" | cut -f1)) for ${ABIS[*]}"
