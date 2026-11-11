# kobvlc

LibVLC as kobbler's apps ship it, with a short series of patches on top and the modules
playback never touches left out:

All are built from one VLC, `VLC_COMMIT` in `versions.env`, with one patch series:

- **Android** — VideoLAN's [libvlcjni](https://code.videolan.org/videolan/libvlcjni) pinned
  to a known commit, built in their CI image against their prebuilt contribs. kobapp
  depends on it as `dev.kobbler.vlc:libvlc-all:<VERSION>`. The pin is
  [MR !246](https://code.videolan.org/videolan/libvlcjni/-/merge_requests/246), libvlcjni's
  port to the libvlc API as reworked in June 2026, until VideoLAN merges it.
- **Linux desktop** — VLC itself, built in an Arch container against Arch's own libraries,
  as a relocatable tree kobapp unpacks into its resources
  (`dev.kobbler.vlc:libvlc-linux-x64:<VERSION>`). It runs on Arch and its derivatives.
- **iOS** — VLC itself, built by its own `extras/package/apple/build.sh` for arm64 devices
  (against VideoLAN's prebuilt contribs) and the arm64 simulator (contribs from source), as a
  static `libvlc.xcframework` kobapp links through the libvlc C API
  (`dev.kobbler.vlc:libvlc-ios:<VERSION>`). The archive carries the SDK frameworks and
  libraries it needs as linker options, so whatever links it needs no flags of its own.

Everything VideoLAN publishes stays theirs. This repo only holds what differs.

## What differs

`patches/vlc/` — applied to VLC, after libvlcjni's own series on Android:

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
| decoder: grow the picture pool when nothing would give one back | Skipping into an HEVC title froze it for good. Each of libavcodec's ten frame threads made up the references the seek left it without, until they held all 40 pictures of the decoder's pool. The next request waited on the pool, the decoder thread waited on that request, and the input waited on the decoder's first picture, so the stop that followed never returned. The made-up references stay held until the decoder has decoded well past them. The pool now grows by a picture when it is empty and nothing is queued for display, which keeps only the picture on screen, or while the decoder is flushed or deleted. Grown pictures stay in the pool, and an output with pictures still to show throttles the decoder as before. VLC's decoder tests cover a decoder holding every picture before its first output, past it, and through a flush. |
| input: let a resume cancel a pause waiting for the buffering to end | A pause asked for while the input buffers waits for the buffering to end, and the input reads as playing meanwhile. A resume in that window found nothing paused and left the pause to land afterwards, so a title held as it opened (a preload, or a pause straight after play) and resumed at once stayed paused with nothing to resume it. VLC's player tests cover it. |
| http: h2conn: ignore frames on streams we reset | A seek resets the stream it was reading, but the server has by then sent up to a receive window (1 MiB) of DATA on it. VLC logged each such frame as an error and answered it with another RST_STREAM, a couple of hundred per seek. RFC 9113 §5.1 says to ignore them; frames on a stream VLC never opened are still errors. VLC's h2conn tests cover it. |

`patches/libvlcjni/`:

| Patch | Why |
|---|---|
| MediaPlayer: select the video track again when the surface returns | A paused video came back black after backgrounding. |
| buildsystem: allow extra modules to be left out | Hooks `modules-blacklist` into the build. |
| AWindow: keep the window size when a vout unregisters | The size belongs to the surface, which outlives the vout. Forgotten on unregister, a vout that registered next had nothing to replay and placed the picture at its source size from the top-left corner: a 640x360 episode after a 1080p one played as a small picture in the corner of a green screen. |
| MediaPlayer: add resume() | `play()` only resumes a player that already reads as paused, so a pause still on its way (a preload held as it opened) landed after it and the title stayed paused. `resume()` queues behind the pause, as `libvlc_media_player_set_pause(mp, 0)`. |

`modules-blacklist` — encoders, stream output, discs, network shares, scripting and the
like, left out of every build. See the file for the list and the reasoning.

## Building

Needs Docker (iOS: a Mac with Xcode instead, a Python 3.10+ for VLC's meson and a GNU make
4.3+, as `KOBVLC_PYTHON` and `KOBVLC_MAKE` when the first `python3` and `make` on the
`PATH` are macOS's own); Android also needs a JDK 21 (`KOBVLC_JAVA_HOME`, default
`/usr/lib/jvm/java-21-openjdk` as Arch installs it; Debian/Ubuntu:
`/usr/lib/jvm/java-21-openjdk-amd64`) and an Android SDK (`ANDROID_HOME`).

```bash
android/build.sh             # every ABI, into work/maven
android/build.sh arm64 arm   # just these, for trying a change on a device
linux/build.sh               # work/linux/libvlc-linux-x64-<VERSION>.tar.gz
ios/build.sh                 # work/ios/libvlc-ios-<VERSION>.tar.gz, on a Mac
android/test.sh              # host tests of the Android patches, on the tree a build patched
```

The first build clones the sources into `work/` (and, for Android, downloads VideoLAN's
prebuilt contribs for `VLC_COMMIT`); later builds reset the trees to the pins, reapply the
patches and rebuild only what changed. kobapp builds against local output with `-Pkobvlc.linux=<this repo>/work/linux/pkg`
(desktop), `-Pkobvlc.maven=<this repo>/work/maven` (Android) and
`-Pkobvlc.ios=<this repo>/work/ios/libvlc.xcframework` (iOS).

## Publishing

Bump `VERSION` in `versions.env` for every change that ships (`4.0.0-<VLC short hash>-kob1`
for a new VLC, `-kob2` for our own change on the same one), then:

```bash
android/build.sh && android/publish.sh
linux/build.sh && linux/publish.sh
ios/build.sh && ios/publish.sh
```

`android/publish.sh` attaches the AAR and an Ivy descriptor to a GitHub release
`v<VERSION>`; `linux/publish.sh` attaches the tarball to `linux-v<VERSION>`, `ios/publish.sh` the
xcframework to `ios-v<VERSION>`. kobapp
resolves all three from the releases — anywhere, CI included. The scripts authenticate with
`GH_TOKEN`, falling back to `gh auth token` — for the account named by `KOBVLC_GH_USER` when
that's set, e.g. in an untracked `local.env` at the repo root.

## Following VideoLAN

VLC and libvlcjni move separately: `VLC_COMMIT` replaces libvlcjni's `VLC_TESTED_HASH`, so
Android builds the same VLC as desktop.

1. Pick a VLC master commit VideoLAN's CI has packaged Android contribs for: the commit
   `extras/ci/get-contrib-sha.sh android-arm64` names at it must have a
   `vlc-contrib-aarch64-linux-android-<sha>.tar.zst` under
   `https://artifacts.videolan.org/vlc/android-arm64/` (and likewise for the other ABIs).
   Building contribs from source takes hours per ABI.
2. Set `VLC_COMMIT` and `VERSION` in `versions.env`.
3. `android/build.sh arm64` — the quickest way to find out whether the patches still apply.
   A patch that upstream has taken is deleted here; one that conflicts is fixed in
   `work/libvlcjni/vlc` and exported again (see below). Then `android/test.sh`.
4. `linux/build.sh`, kobapp's desktop tests against it, and a device try of the Android build.
5. `android/build.sh && android/publish.sh`, `linux/publish.sh`, and bump `libvlc-android`
   and `libvlc-linux` in kobapp's `gradle/libs.versions.toml`.

libvlcjni moves by setting `LIBVLCJNI_COMMIT` (and `LIBVLCJNI_REF`, the ref to fetch it
from: `refs/merge-requests/246/head` until that MR merges, then `master`). A vlcj release may
need a newer VLC than the one pinned; its natives say which libvlc API it binds.

Every patch here is written to be sent upstream; each one VideoLAN takes is one less to carry.

## Changing VLC

Work in `work/libvlcjni/vlc` (or `work/vlc-linux`, the same VLC), commit, then export with
`git format-patch --thread -o ../../../patches/vlc/` and give each patch a
`Message-Id:` header — libvlcjni's build checks the series is applied by it.

## Licence

LibVLC is LGPL-2.1-or-later, and several of its modules are GPL. The patches here are
under the same terms as the files they change; everything else in this repository is under
the LGPL-2.1 in [LICENSE](LICENSE), as libvlcjni is.
