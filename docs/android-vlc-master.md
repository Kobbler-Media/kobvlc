# Android on VLC master

Android and desktop build one VLC with one patch series, and kobapp's two VLC players bind
the same reworked libvlc API. This is how that came about, and what is still open.

## Where things stand (2026-11-11)

| | Android | Desktop |
|---|---|---|
| Binding | libvlcjni MR !246 head `6ad75b5d` | vlcj 5.0.0-M6 |
| VLC | `fb39292a` (master, 2026-11-10) | the same |
| Patches | `patches/vlc/` + `patches/libvlcjni/` | `patches/vlc/` |
| Version | `4.0.0-fb39292a-kob2` | the same |

Before this, Android built libvlcjni master's VLC (`c84ef1ed`, June 2026), 2,191 commits
behind desktop's, against the libvlc API from before the June 2026 rework. Every patch was
applied to two VLCs five months apart, and one desktop fix (the pause deferred to the end of
buffering) had nowhere to go on Android.

## How

- **libvlcjni at [MR !246](https://code.videolan.org/videolan/libvlcjni/-/merge_requests/246)**,
  "Port libvlcjni to the reworked libvlc 4 API": open, CI green, unchanged since 2026-10-30.
  `android/build.sh` fetches it from `LIBVLCJNI_REF`, since `origin` does not carry MR refs.
- **VLC at `VLC_COMMIT`**, not the MR's `VLC_TESTED_HASH` (`15b71e3f`): Android went straight to
  desktop's VLC. libvlc's API differs between the two only in `libvlc_audio_flush_cb`, which
  libvlcjni does not use. libvlcjni's own VLC patches apply to it unchanged.
- **Prebuilt contribs.** VideoLAN's CI packages Android contribs for most contrib changes on
  master, now as `.tar.zst`; `978212a4`, the contrib commit at `fb39292a`, has them for all
  four ABIs. None exist for the MR's VLC, which is why it was skipped.
- **`patches/vlc-desktop/` folded into `patches/vlc/`** as 0017.
- **`patches/libvlcjni/0004` (`resume()`)** ported to the rewritten `MediaPlayer`; the MR has no
  resume. 0001 (select the video track again when the surface returns) applies and still fits
  the rewritten surface callbacks.

kobapp's `AndroidPlayer` moved to the MR's API:

- events come through a `MediaPlayer.Listener` given at construction, mapped as desktop maps
  vlcj's: `onStateChanged` (opening, playing, paused, error), `onMediaStopping` (the end or
  stop, through `stateOnStopping`), `onBufferingChanged` (a fraction now),
  `onCapabilitiesChanged` (pausable), `onPositionChanged`, `onLengthChanged`,
  `onTrackListChanged`, `onTrackSelectionChanged`, `onVoutChanged`;
- times are microseconds;
- `stop()` is `stopAsync()`; a stop that a new title or `Player.stop()` waits on polls for the
  input to go (now the shared `stopAndWait`);
- `Media` takes no `LibVLC`.

## Checked on devices

Pixel 6 Pro (arm64), Debug profile, South Park S1 (H.264 720p MKV over HTTP/2):
MediaCodec (`c2.exynos.h264.decoder`) through ASurfaceControl, AAudio, resume at the saved
mark, pause and resume, seek, a paused picture back after backgrounding, the next episode
opened mid-title, and a title's end playing the next one.

Chromecast HD (armeabi-v7a): Law & Order S1E1, HEVC Main 10 960x720 on
`c2.amlogic.hevc.decoder`, two bursts of skips with playback carrying on and no stall
reported. The colour of the 10-bit picture needs eyes on the TV: screencap shows the video
plane black.

`android/test.sh` passes against the new tree (pacing, image reader usage, AAudio fade).

Not rechecked: frame pacing as the panel shows it, a smaller episode after a 1080p one,
resume after a long pause on a burst read.

## Open

- **Follow the MR.** Move `LIBVLCJNI_COMMIT` to the merge commit (`LIBVLCJNI_REF=master`) once
  VideoLAN merges it; if it changes before then, follow it. It is a breaking Java API change,
  so it may take a while.

## Fixed since

- **HTTP/2 noise after a cancelled transfer** (`patches/vlc/0018`). Each DATA frame already in
  flight for a stream VLC reset (every seek, through `patches/vlc/0002`) was logged as "local
  stream N error: Stream closed" and answered with another RST_STREAM: 67 and 125 frames
  after two seeks on the Pixel, so at most the 1 MiB stream window the server may have in
  flight, never more. Nothing was hiding there; RFC 9113 §5.1 says to ignore such frames, and
  the patch does, for streams VLC opened and closed only.

## Shared player code

`VlcPlayer` in `commonMain` (kobapp's kobplayer) holds what both players do with libVLC 4: the
state machine its events drive, ignoring events from a retired input, holding a pause asked
for before the input can take it, picking a title back up on a fresh player after a stall,
stopping and waiting for the input to go, seeks, tracks, chapters, declining the subtitle VLC
picks after the app asked for none, and the media options. Each platform binds it through a
small `VlcBinding`: `VlcjBinding` on desktop, `LibVlcBinding` on Android. What stays per
platform: Android's surfaces, audio focus and routing, MediaCodec decoder choices and
field-decode probing; desktop's frame sink, gain fades and decoder device. The iOS port's
VLCKit 4 (also libvlc 4) would be a third binding.
