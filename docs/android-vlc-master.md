# Android on VLC master

Plan for building Android and desktop from one VLC, with one patch series, and for sharing
more of kobapp's player code between them once both bind the same libvlc API. Written
2026-11-11; the numbers below are from that day.

## Where things stand

| | Android | Desktop |
|---|---|---|
| Binding | libvlcjni `a8d53a91` (master, 2026-07-08) | vlcj 5.0.0-M6 |
| VLC | `c84ef1ed` (2026-06-13), libvlcjni's `VLC_TESTED_HASH` | `fb39292a` (master, 2026-11-10) |
| libvlc API | before the June 2026 rework | after it |
| Patches | `patches/vlc/` | `patches/vlc/` + `patches/vlc-desktop/` |

Android's VLC is 2,191 commits behind master, 69 of them in code Android plays through
(mediacodec, the Android display and audio outputs, decoder, player, http, mkv). libvlcjni
master binds the libvlc API from before the rework (event manager, media events, `parse()`),
so it does not build against VLC master, and Android cannot move on its own.

Every patch is applied to two VLCs five months apart. `patches/vlc-desktop/` already holds
one fix for code Android's VLC does not have yet (the pause deferred to the end of
buffering), and the next one will not apply to both either.

## The way across: libvlcjni MR !246

https://code.videolan.org/videolan/libvlcjni/-/merge_requests/246, "Port libvlcjni to
the reworked libvlc 4 API". Open, mergeable, CI green, last updated 2026-10-30. Head
`6ad75b5dbc39`, fetchable as `refs/merge-requests/246/head`.

- Pins VLC `15b71e3fa6d4` (2026-09-23): an ancestor of the desktop pin, 506 commits behind
  it.
- All of `patches/vlc/` and `patches/vlc-desktop/` apply to that VLC.
- `patches/libvlcjni/` 0001–0003 apply to the MR head. 0004 (`MediaPlayer.resume()`) does
  not: `MediaPlayer` was rewritten, and it needs porting. 0001 (select the video track
  again when the surface returns) applies, but needs checking against the rewritten
  `MediaPlayer`.

What the MR changes for its users (a breaking Java API change):

- Events go: each object takes a `Listener` at construction, with per-object callbacks.
  Objects passed to callbacks are borrowed; `retain()` keeps them. Nothing is delivered after
  `release()`. Callbacks arrive on the main thread.
- Times are microseconds: `getTime()`, `setTime()` (now returns `int`), `getLength()`,
  `Media.getDuration()`, chapter and title durations.
- `stop()` becomes `stopAsync()`. `onStateChanged(Stopped)` reports the end of the stop.
- `IMedia.State` moves to `MediaPlayer.State`, with libvlc 4's values (`Ended` becomes
  `Stopping`).
- `Media.parse()`, `parseAsync()`, `IMedia.Parse` and `IMedia.ParsedStatus` go; `Parser`
  replaces them, and thumbnails and attachments come back as `Picture`.
- `MediaList` goes.

## Steps

1. **Pin libvlcjni at the MR.** `LIBVLCJNI_COMMIT=6ad75b5dbc39…`, fetched from the MR ref
   (`android/build.sh` fetches `origin`, which does not carry MR refs). Move to the merge
   commit once VideoLAN merges it; if it changes before then, follow it.
2. **Build the contribs.** VideoLAN publishes prebuilt Android contribs only for the hashes
   its CI packaged, and neither the MR's VLC nor master has them (404 at
   `artifacts.videolan.org/vlc/android-arm64/…`). `buildsystem/compile-libvlc.sh` builds them
   from source without `--with-prebuilt-contribs`, and `--package-contribs` packages them.
   Build once per ABI and keep the packages under `work/`, keyed by
   `extras/ci/get-contrib-sha.sh`, so a rebuild reuses them. Take the build image from VLC's
   own CI file at that hash if libvlcjni's no longer matches.
3. **Land on the MR's VLC first** (`15b71e3f`): it is what the MR was tested against. Build,
   run `android/test.sh`, try it on devices (below).
4. **Then one VLC for both.** Move Android to the desktop pin, replace
   `VLC_DESKTOP_COMMIT`/`DESKTOP_VERSION` in `versions.env` with one VLC commit, fold
   `patches/vlc-desktop/` into `patches/vlc/`, and drop the split from `linux/build.sh` and
   the README.
5. **Port `patches/libvlcjni/0004`** (`resume()`) to the rewritten `MediaPlayer`, or drop it
   if the MR's API offers a resume (`libvlc_media_player_set_pause(mp, 0)`).
6. **Port kobapp's `AndroidPlayer`** (`kobplayer/src/androidMain`). It is the only file in
   kobapp that touches libvlcjni, about 25 call sites:
   - the `MediaPlayer.Event` handler (`listenTo`) becomes a `Listener`;
   - `time`, `length`, `setTime` move to microseconds;
   - every `stop()` becomes `stopAsync()`. `CommandLane.replaceTitle`'s stop has to wait
     for the stop to finish before the next title opens, or media handed to a player that
     is still playing is swapped in without an opening;
   - `IMedia.State` becomes `MediaPlayer.State`;
   - `Media.stats` (`sampleDecoder`) and anything else the MR moved.
7. **Verify on devices.** Pixel 6 Pro and Chromecast HD (the `boreal` devices on adb). Check
   what the Android patches fixed: frame pacing at 24/25fps on 60Hz (`android/test.sh` covers
   the maths, the panel shows the rest), 10-bit HEVC on the Chromecast (was solid green),
   AAudio fade-in and sample rate, a video track coming back after backgrounding, a smaller
   episode after a 1080p one (was drawn in the corner), resume after a long pause on a burst
   read, and a skip in an HEVC title.

## Sharing player code

With both bindings on the reworked libvlc API, `AndroidPlayer` (about 980 lines) and
`DesktopPlayer` (about 700) differ mostly in the binding underneath, not in what they do
with it. Already shared in `commonMain`: `CommandLane` (one thread per native player, stuck
calls escaped and reported), the state helpers (`stateOnStopping`, `stateOnBuffering`,
`stateAfterClockAdvance`, `playPauseIntent`), `watchFrozenClock`, seek clamping, `PlayerStall`.

Duplicated today, and worth one implementation:

- holding a title asked to pause before it can (`pausable`, `pauseWhenPausable`,
  `holdIfAsked`), and the resume that cancels it;
- picking a title back up on a fresh player (`resumeTitle`) and adopting it;
- the event handling that maps libvlc's playing, paused, buffering, end and error onto
  `PlayerState`, including ignoring events from a retired input (`inputRetired`);
- track and chapter reloads, and declining the default subtitle VLC picks after the app asked
  for none;
- media options (`vlcMediaOptions` on desktop, `media()` on Android build the same list).

A shape for it: a small `VlcBinding` interface in `commonMain` (open, play, stop, pause,
resume, set time and rate, tracks, chapters, and a listener for libvlc's callbacks), a vlcj
adapter on desktop and a libvlcjni adapter on Android, and one `VlcPlayer` in common that
holds the state machine above. What stays per platform: Android's surfaces, audio focus and
routing, MediaCodec decoder choices and field-decode probing; desktop's frame sink and
decoder device. The iOS port's VLCKit 4 (also libvlc 4) could take a third adapter.

Do this after step 6, not with it: porting `AndroidPlayer` to the new API and then lifting
the shared part out are two reviewable changes, and the second is much smaller once the first
has made the two players line up.

## Risks

- The MR is unmerged and may change. It is also a breaking Java API change, which is why
  VideoLAN may take a while over it.
- 2,191 VLC commits land on Android at once. The device checks above are the safety net.
  Bisecting means building VLC between `c84ef1ed` and the new pin, with contribs.
- Building contribs from source is hours the first time for four ABIs. Keep the packages.
