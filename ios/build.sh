#!/usr/bin/env bash
# Builds libvlc for iOS: VLC at VLC_COMMIT with patches/vlc on top, by VLC's own
# extras/package/apple/build.sh, for arm64 devices and the arm64 simulator. Packaged as a
# static libvlc.xcframework under work/ios: libvlc, libvlccore, the plugins kept and their
# contribs in one archive per platform, with the C headers. Needs a Mac with Xcode.
#
# Devices build against VideoLAN's prebuilt contribs for VLC_COMMIT; nobody publishes any for
# the arm64 simulator, so its contribs build from source the first time, which takes hours.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
SRC="$WORK/vlc-ios"
OUT="$WORK/ios"
GIT_AS_BUILD=(git -c user.name=kobvlc -c user.email=kobvlc@build.invalid -c commit.gpgsign=false)

# What libvlc's archive needs from the SDK.
FRAMEWORKS=(
  AudioToolbox AVFoundation AVKit CoreFoundation CoreGraphics CoreImage CoreMedia CoreText
  CoreVideo Foundation Metal OpenGLES QuartzCore Security UIKit VideoToolbox
)
LIBS=(c++ iconv)

[ -d "$SRC/.git" ] || git clone -q --no-checkout "$VLC_URL" "$SRC"
git -C "$SRC" cat-file -e "$VLC_COMMIT" 2>/dev/null || git -C "$SRC" fetch -q origin "$VLC_COMMIT"
git -C "$SRC" am --abort 2>/dev/null || true
git -C "$SRC" reset -q --hard "$VLC_COMMIT"
"${GIT_AS_BUILD[@]}" -C "$SRC" am -q "$ROOT"/patches/vlc/*.patch
MIN_IOS="$(sed -n 's/^export VLC_DEPLOYMENT_TARGET_IOS_arm64="\(.*\)"/\1/p' "$SRC/extras/package/apple/build.conf")"

# VLC's removal step matches plugin archives by glob, not regex.
BLACKLIST="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/modules-blacklist" | sed 's/\.\*/*/g')"
if grep -qE '[].^$()|+?{}\\[]' <<< "$BLACKLIST"; then
  echo "modules-blacklist has a regex ios/build.sh cannot turn into a glob" >&2
  exit 1
fi
export KOBVLC_BLACKLIST_GLOBS="$(tr '\n' ' ' <<< "$BLACKLIST")"

CONTRIB_SHA="$(cd "$SRC" && extras/ci/get-contrib-sha.sh ios-arm64)"

# The contribs' meson needs Python 3.10+ and runs the first python3 on a PATH cut down to VLC's
# own tool directories and /usr/bin, where macOS keeps 3.9.
PYTHON="${KOBVLC_PYTHON:-$(command -v python3)}"
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
  { echo "meson needs Python 3.10+: point KOBVLC_PYTHON at one" >&2; exit 1; }

# The ninja VLC's tools build shares make's jobserver and leaves its pipe non-blocking, and
# macOS's make 3.81 then gives up mid-build reading it. GNU make 4.3+ waits instead.
GNU_MAKE="${KOBVLC_MAKE:-$(command -v gmake || command -v make)}"
"$GNU_MAKE" --version | awk 'NR == 1 { split($3, v, "."); exit !(v[1] > 4 || (v[1] == 4 && v[2] >= 3)) }' ||
  { echo "the contribs need GNU make 4.3+: point KOBVLC_MAKE at one" >&2; exit 1; }
export MAKE="$GNU_MAKE"

mkdir -p "$SRC/extras/tools/build/bin"
ln -sf "$PYTHON" "$SRC/extras/tools/build/bin/python3"
ln -sf "$GNU_MAKE" "$SRC/extras/tools/build/bin/make"

# Linker options carried in the object that holds the static module list, which libvlccore
# always pulls in: whatever links the archive gets the SDK libraries with it, without being told.
autolink() {
  local f l
  for f in "${FRAMEWORKS[@]}"; do printf '__asm__(".linker_option \\"-framework\\", \\"%s\\"");\n' "$f"; done
  for l in "${LIBS[@]}"; do printf '__asm__(".linker_option \\"-l%s\\"");\n' "$l"; done
}

# macOS's own bash is 3.2, which VLC's script is written for: no associative arrays here.
build() {
  local sdk="$1" target="$2" prebuilt="${3:-}" dir="$OUT/$1"
  mkdir -p "$dir"
  (cd "$dir" && VLC_PREBUILT_CONTRIBS_URL="$prebuilt" "$SRC/extras/package/apple/build.sh" \
    --sdk="$sdk" --arch=arm64 --disable-debug --config="$ROOT/ios/build.conf" \
    ${prebuilt:+--with-prebuilt-contribs}) > "$dir/build.log" 2>&1 \
    || { tail -n 40 "$dir/build.log" >&2; echo "$sdk build failed, see $dir/build.log" >&2; exit 1; }

  local lib="$dir/static-lib"
  { cat "$lib/static-module-list.c"; echo; autolink; } > "$lib/kobvlc-module-list.c"
  xcrun --sdk "$sdk" clang -target "$target" -I"$SRC/include" -I"$dir/build" \
    -c "$lib/kobvlc-module-list.c" -o "$lib/kobvlc-module-list.o"
  sed "s|/static-module-list\.o\$|/kobvlc-module-list.o|" "$lib/static-libs-list" > "$lib/kobvlc-libs-list"
  rm -rf "$dir/pkg" && mkdir -p "$dir/pkg/include"
  xcrun libtool -static -no_warning_for_no_symbols -filelist "$lib/kobvlc-libs-list" -o "$dir/pkg/libvlc.a"
  xcrun strip -S "$dir/pkg/libvlc.a"
  cp -R "$dir/vlc-$sdk-arm64/include/vlc" "$dir/pkg/include/"
}

build iphoneos "arm64-apple-ios$MIN_IOS" \
  "https://artifacts.videolan.org/vlc/ios-arm64/vlc-contrib-arm64-apple-iphoneos-$CONTRIB_SHA.tar.zst"
build iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"

rm -rf "$OUT/libvlc.xcframework"
xcodebuild -create-xcframework -output "$OUT/libvlc.xcframework" \
  -library "$OUT/iphoneos/pkg/libvlc.a" -headers "$OUT/iphoneos/pkg/include" \
  -library "$OUT/iphonesimulator/pkg/libvlc.a" -headers "$OUT/iphonesimulator/pkg/include" >/dev/null

ARCHIVE="$OUT/libvlc-ios-$VERSION.tar.gz"
rm -f "$ARCHIVE"
tar -C "$OUT" -czf "$ARCHIVE" libvlc.xcframework
echo "built $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1), $(grep -c _plugin "$OUT/iphoneos/static-lib/static-libs-list") plugins)"
