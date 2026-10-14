#!/usr/bin/env bash
# Builds libvlc for Linux x86_64: VLC at VLC_DESKTOP_COMMIT with patches/vlc on top,
# compiled in an Arch container against Arch's own libraries. Packaged as a relocatable
# tree — libvlc finds its plugins next to itself — under work/linux.
#
# The libraries it links (ffmpeg, libva, libass, ...) come from the system at run time, so
# the result runs on Arch and its derivatives, and needs a rebuild when one of them
# changes its soname.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"
WORK="${KOBVLC_WORK:-$ROOT/work}"
SRC="$WORK/vlc-linux"
OUT="$WORK/linux"
IMAGE=archlinux:base-devel
GIT_AS_BUILD=(git -c user.name=kobvlc -c user.email=kobvlc@build.invalid -c commit.gpgsign=false)

[ -d "$SRC/.git" ] || git clone -q --no-checkout "$VLC_URL" "$SRC"
git -C "$SRC" cat-file -e "$VLC_DESKTOP_COMMIT" 2>/dev/null || git -C "$SRC" fetch -q origin "$VLC_DESKTOP_COMMIT"
git -C "$SRC" am --abort 2>/dev/null || true
git -C "$SRC" reset -q --hard "$VLC_DESKTOP_COMMIT"
"${GIT_AS_BUILD[@]}" -C "$SRC" am -q "$ROOT"/patches/vlc/*.patch

BLACKLIST="$(grep -vE '^\s*(#|$)' "$ROOT/modules-blacklist" | paste -sd'|')"

rm -rf "$OUT/stage"
mkdir -p "$OUT"
docker run --rm -v "$SRC:/src" -v "$OUT:/out" -w /src -e BLACKLIST="$BLACKLIST" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$IMAGE" bash -euc '
    pacman -Syu --noconfirm --needed -q \
      git autoconf automake libtool gettext pkgconf flex bison python wget \
      ffmpeg libva libdrm libass freetype2 fribidi harfbuzz fontconfig libxml2 gnutls \
      libdvbpsi libmatroska libebml zvbi libvpx dav1d a52dec libdca libmad mpg123 libmpeg2 \
      flac opus libvorbis speex libsoxr libpulse alsa-lib libxcb xcb-util-keysyms ffnvcodec-headers patchelf >/dev/null
    useradd -u "$HOST_UID" -o -m build
    chown -R build /src /out
    runuser -u build -- bash -euc "
      [ -f configure ] || ./bootstrap >/dev/null
      mkdir -p build-linux && cd build-linux
      [ -f config.status ] || ../configure --prefix=/opt/kobvlc --disable-static \
        --disable-debug --disable-qt --disable-skins2 --disable-lua --disable-nls --disable-vlc \
        --disable-chromecast --disable-sout --disable-bluray --disable-dvdread --disable-dvdnav \
        --disable-smb2 --disable-nfs --disable-sftp --disable-upnp --disable-microdns \
        --disable-live555 --disable-taglib --disable-archive --disable-gme --disable-fluidsynth \
        --disable-mod --disable-aribcaption --disable-libplacebo --disable-vulkan --disable-srt --disable-x264 \
        --disable-x26410b --disable-twolame --disable-aom >/dev/null
      make -j\$(nproc) >/dev/null
      make install DESTDIR=/out/stage >/dev/null
      # The system may have a libvlccore of its own, from VLC 3: ours must win wherever we are.
      patchelf --force-rpath --set-rpath \\\$ORIGIN /out/stage/opt/kobvlc/lib/libvlc.so.*.*.*
    "
    # Plugins find their helper libraries (libvlc_pulse, ...) two levels up, not under the
    # prefix they were built for.
    find /out/stage/opt/kobvlc/lib/vlc/plugins -name "*.so" -exec \
      patchelf --force-rpath --set-rpath "\$ORIGIN/../..:\$ORIGIN/../../.." {} +
    chown -R "$HOST_UID:$HOST_GID" /src /out
  '

# Keep only what a player loads: libvlc, libvlccore and the plugins not left out.
TREE="$OUT/stage/opt/kobvlc"
find "$TREE/lib/vlc/plugins" -name '*.so' | while read -r plugin; do
  name="$(basename "$plugin" .so)"; name="${name#lib}"; name="${name%_plugin}"
  if echo "$name" | grep -qxE "$BLACKLIST"; then rm -f "$plugin"; fi
done
find "$TREE/lib/vlc/plugins" -name '*.la' -delete
find "$TREE/lib/vlc/plugins" -type d -empty -delete
mkdir -p "$OUT/pkg/lib"
rm -rf "$OUT/pkg/lib"/*
# One file per library, as Gradle unpacks a symlink as an empty file. libvlc and libvlccore
# under the names JNA looks up: a miss falls through to the system's libvlc. vlcj loads
# libvlccore first, which is what then satisfies libvlc's dependency on it by soname.
cp -L "$TREE/lib/libvlc.so" "$TREE/lib/libvlccore.so" "$OUT/pkg/lib/"
# The plugins' helpers under their sonames.
by_soname() {
  local soname
  soname="$(readelf -d "$1" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
  cp -L "$1" "$2/$soname"
}
mkdir -p "$OUT/pkg/lib/vlc"
cp -a "$TREE/lib/vlc/plugins" "$OUT/pkg/lib/vlc/"
for helper in "$TREE"/lib/vlc/*.so; do by_soname "$helper" "$OUT/pkg/lib/vlc"; done
rm -rf "$OUT/pkg/lib/vlc/vlc-cache-gen" "$OUT/pkg/lib/vlc/lua"
strip --strip-unneeded "$OUT"/pkg/lib/libvlc*.so* $(find "$OUT/pkg/lib/vlc/plugins" -name '*.so')

ARCHIVE="$OUT/libvlc-linux-x64-$DESKTOP_VERSION.tar.gz"
tar -C "$OUT/pkg" -czf "$ARCHIVE" lib
echo "built $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1), $(find "$OUT/pkg/lib/vlc/plugins" -name '*.so' | wc -l) plugins)"
