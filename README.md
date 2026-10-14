# kobvlc

LibVLC as kobbler's apps ship it: VideoLAN's [libvlcjni](https://code.videolan.org/videolan/libvlcjni)
pinned to a known commit, with a short series of patches on top and the modules
playback never touches left out. kobapp depends on the result as
`dev.kobbler.vlc:libvlc-all:<version>`.

Everything VideoLAN publishes stays theirs: the AAR is built from their sources, in
their CI image, against their prebuilt contribs. This repo only holds what differs.

## What differs

`patches/vlc/` — applied to VLC after libvlcjni's own series:

| Patch | Why |
|---|---|
| android display: release the window surface on close | The player keeps a vout for the next video. Without this, a vout reused after the app's surface was replaced (backgrounding, leaving the player) drew into the dead surface and the picture stayed black. The GL and Vulkan displays already did this. |
| http: stop the old transfer before seeking | Over HTTP/2 the response to a seek queued behind the abandoned transfer's data; opening a Matroska file waited over a second on the jump to its cues. |
| mediacodec: find the decoder without probing every codec | Every stream open asked every codec on the device for capabilities it did not have, and threw for each. Several hundred ms per open on a Chromecast; now looked up once. |

`patches/libvlcjni/`:

| Patch | Why |
|---|---|
| MediaPlayer: select the video track again when the surface returns | A paused video came back black after backgrounding. |
| buildsystem: allow extra modules to be left out | Hooks `android/modules-blacklist` into the build. |

`android/modules-blacklist` — encoders, stream output, discs, network shares, scripting
and the like. See the file for the list and the reasoning.

## Building

Needs Docker, a JDK 21 (`KOBVLC_JAVA_HOME`, default `/usr/lib/jvm/java-21-openjdk`) and an
Android SDK (`ANDROID_HOME`).

```bash
android/build.sh             # every ABI, into work/maven
android/build.sh arm64 arm   # just these, for trying a change on a device
```

The first build clones libvlcjni and VLC into `work/` and downloads the contribs;
later builds reset both trees to the pins, reapply the patches and rebuild only what
changed.

## Publishing

Bump `VERSION` in `versions.env` for every change that ships, then:

```bash
android/build.sh && maven/publish.sh
```

`publish.sh` copies the version to the Maven host and keeps only the newest two there.
The host serves `maven/data` with `maven/compose.yml` (`docker compose up -d` from `maven/`).

## Changing VLC

Work in `work/libvlcjni/vlc`, commit, then export with
`git format-patch --thread -o ../../../patches/vlc/` and give each patch a
`Message-Id:` header — libvlcjni's build checks the series is applied by it.

## Licence

LibVLC is LGPL-2.1-or-later, and several of its modules are GPL. The patches here are
under the same terms as the files they change.
