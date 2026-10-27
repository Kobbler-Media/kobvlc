# kobvlc

LibVLC as kobbler's apps ship it, with a short series of patches on top and the modules
playback never touches left out:

- **Android** — VideoLAN's [libvlcjni](https://code.videolan.org/videolan/libvlcjni) pinned
  to a known commit, built in their CI image against their prebuilt contribs. kobapp
  depends on it as `dev.kobbler.vlc:libvlc-all:<VERSION>`.
- **Linux desktop** — VLC itself at `VLC_DESKTOP_COMMIT`, built in an Arch container against
  Arch's own libraries, as a relocatable tree kobapp unpacks into its resources
  (`dev.kobbler.vlc:libvlc-linux-x64:<DESKTOP_VERSION>`). It runs on Arch and its
  derivatives. Desktop follows VLC master because vlcj 5 binds the libvlc API as reworked in
  June 2026, which libvlcjni's VLC predates; once libvlcjni moves past that, both can share
  one VLC again.

Everything VideoLAN publishes stays theirs. This repo only holds what differs.

## What differs

`patches/vlc/` — applied to VLC after libvlcjni's own series:

| Patch | Why |
|---|---|
| android display: release the window surface on close | The player keeps a vout for the next video. Without this, a vout reused after the app's surface was replaced (backgrounding, leaving the player) drew into the dead surface and the picture stayed black. The GL and Vulkan displays already did this. |
| http: stop the old transfer before seeking | Over HTTP/2 the response to a seek queued behind the abandoned transfer's data; opening a Matroska file waited over a second on the jump to its cues. The old response's headers are kept, so the new request is still validated against its ETag. |
| mediacodec: find the decoder without probing every codec | Every stream open asked every codec on the device for capabilities it did not have, and threw for each. Several hundred ms per open on a Chromecast; now looked up once. |
| decoder device: let the user pick the device node | With more than one GPU, VA-API decoded on whichever render node it found first. `dec-dev-path` names the one to open. |
| libvlc: let the app choose the decoder device | A player drawing through video callbacks always decoded in software. `libvlc_video_set_decoder_device()` picks the module and node per player, and a reused vout reopens its device when the choice changes. |
| aaudio: open the stream at the source sample rate | Unspecified, AAudio offered the device's 96kHz on a Pixel 10 and VLC resampled every 48kHz track up for AudioFlinger to bring back down. |
| android display: pace release times to the vsync | Each picture asked SurfaceFlinger for the date its millisecond timestamp gave it. Held to 24Hz at 120Hz, a Pixel 6 Pro latched a request a fraction of a millisecond late a whole frame later, and every few seconds a burst of held and dropped frames went by. Release times are now fitted to the frame duration and moved onto the closest vsync, as Media3 does. |
| stream prefetch: read in bursts once the buffer is full | Once full, the buffer was topped up by every read that freed space in it, so a network stream trickled in at its bitrate for the whole title and the Wi-Fi or cellular radio never got to sleep. `prefetch-refill-level` leaves the source idle until the unread data has drained to that share of the buffer, then refills it in one burst, as ExoPlayer does. kobapp sets it, and the buffer size, per player. |
| http/2: refuse new streams once the connection has shut down | A server closing an idle connection left it cached, and the next request on it (the resume after a burst's idle stretch, or a seek) waited forever for a reply nothing was left to receive. Playback froze with no buffering shown. |
| http: do not resume reading for a reader being stopped | The resume after an interrupted read could wait out of the interrupt's reach on a dead connection, and the input never stopped. |
| http: notice connections whose peer stopped acknowledging | A connection lost without a word (NAT, Wi-Fi) was never noticed. TCP keep-alive (also running between read-ahead bursts) and an 8s limit on unacknowledged data fail it within about ten seconds, inside what the player has buffered, and the transfer resumes on a new connection. |
| android display: keep paced releases on one cadence | The pacing above still put about 100 frames a minute on the wrong vsync on a Pixel 6 Pro at 60Hz. Media3's hysteresis only suits one phase of cadence, and 25fps at 60Hz has five; the frame timelines are spaced at the nominal 16.667ms on a panel running at 16.58ms; and the clock's dates jitter. Vsyncs now come from a line fitted through the last eight seconds of samples, and the clock's distance from the frames is low-pass filtered. `android/test.sh` checks the cadence on simulated panels. |
| mediacodec: ask the image reader for what a SurfaceView asks | 10-bit HEVC played solid green on a Chromecast HD. The AImageReader whose images go straight to SurfaceFlinger asked for no usage, and Amlogic's decoders take a consumer without the composer bit for a SurfaceTexture: no compressed output, no attributes for the composer, and a 10-bit picture the video plane shows as green. It now asks for the composer and GPU usage a SurfaceView's queue gives a decoder (the GPU alone when VLC's OpenGL display samples the images). `android/test.sh` checks the usage. |
| aaudio: fade in each new stream | Every flush (each seek, and each "way too late" or discontinuity flush after a stall) opens a new stream, and AudioFlinger ramps a pause down but gives a new track no ramp: each one started at full level mid-waveform and clicked. The first 10ms of a new stream, and of audio coming back after an underrun, now ramp in. `android/test.sh` checks the ramp. |
| aaudio: wait for the pause without a dangling if | The wait for the paused state had lost its statement, leaving the next line to run only when the wait failed. |

`patches/libvlcjni/`:

| Patch | Why |
|---|---|
| MediaPlayer: select the video track again when the surface returns | A paused video came back black after backgrounding. |
| buildsystem: allow extra modules to be left out | Hooks `modules-blacklist` into the build. |
| AWindow: keep the window size when a vout unregisters | The size belongs to the surface, which outlives the vout. Forgotten on unregister, a vout that registered next had nothing to replay and placed the picture at its source size from the top-left corner: a 640x360 episode after a 1080p one played as a small picture in the corner of a green screen. |

`modules-blacklist` — encoders, stream output, discs, network shares, scripting and the
like, left out of both builds. See the file for the list and the reasoning.

## Building

Needs Docker; Android also needs a JDK 21 (`KOBVLC_JAVA_HOME`, default
`/usr/lib/jvm/java-21-openjdk`) and an Android SDK (`ANDROID_HOME`).

```bash
android/build.sh             # every ABI, into work/maven
android/build.sh arm64 arm   # just these, for trying a change on a device
linux/build.sh               # work/linux/libvlc-linux-x64-<DESKTOP_VERSION>.tar.gz
android/test.sh              # host tests of the Android patches, on the tree a build patched
```

The first build clones the sources into `work/` (and, for Android, downloads the
contribs); later builds reset the trees to the pins, reapply the patches and rebuild only
what changed. kobapp runs its desktop build against a local Linux build with
`-Pkobvlc.linux=<this repo>/work/linux/pkg`.

## Publishing

Bump `VERSION` (Android) or `DESKTOP_VERSION` (Linux) in `versions.env` for every change
that ships, then:

```bash
android/build.sh && android/publish.sh
linux/build.sh && linux/publish.sh
```

`android/publish.sh` attaches the AAR and an Ivy descriptor to a GitHub release
`v<VERSION>`, and copies the version to the LAN Maven host, which keeps only the newest two.
`linux/publish.sh` attaches the tarball to `linux-v<DESKTOP_VERSION>`. kobapp resolves both
from the releases — anywhere, CI included. The host serves `maven/data` with
`maven/compose.yml` (`docker compose up -d` from `maven/`).

## Following VideoLAN

libvlcjni moves VLC forward by bumping `VLC_TESTED_HASH` and its CI image together; taking
a newer libvlcjni takes both.

1. Set `LIBVLCJNI_COMMIT` in `versions.env` to the new commit and bump `VERSION`
   (`4.0.0-eap30-kob1` for a new upstream release, `-kob2` for our own change on the same one).
2. `android/build.sh arm64` — the quickest way to find out whether the patches still apply.
   A patch that upstream has taken is deleted here; one that conflicts is fixed in
   `work/libvlcjni` or `work/libvlcjni/vlc` and exported again (see below).
3. Try it on a device, then `android/build.sh && android/publish.sh` and bump
   `libvlc-android` in kobapp's `gradle/libs.versions.toml`.

Desktop moves by setting `VLC_DESKTOP_COMMIT` (and `DESKTOP_VERSION`, `4.0.0-<short hash>-kob1`),
`linux/build.sh`, kobapp's desktop tests against it, then `linux/publish.sh` and bumping
`libvlc-linux`. A vlcj release may need a newer VLC than the one pinned; its natives say which
libvlc API it binds. The same patches apply to both trees.

Every patch here is written to be sent upstream; each one VideoLAN takes is one less to carry.

## Changing VLC

Work in `work/libvlcjni/vlc` (or `work/vlc-linux`), commit, then export with
`git format-patch --thread -o ../../../patches/vlc/` and give each patch a
`Message-Id:` header — libvlcjni's build checks the series is applied by it.

## Licence

LibVLC is LGPL-2.1-or-later, and several of its modules are GPL. The patches here are
under the same terms as the files they change.
