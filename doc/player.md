# The player

How the video player inside `eyzflow_player` works: routing, Tizen AVPlay, the native player on Android and iOS, DRM, the TV controls and the playback events. Paths are relative to the package root.

## One entry point

The view has a single constructor and it requires a source. There is no
source-less surface: an app that has no stream to play does not open the
player, and shows its own message instead.

### `VideoplayerFeatureView({required videoSource, ...})`

Source playback. Creates `VideoplayerFeatureBloc` carrying a
`VideoplayerTrailerTarget`, resolves player policy, and drives a controller:

- Tizen plays it through AVPlay (`video_player_avplay`) as HLS. Clear trailer
  sources use no DRM; an authorized feature-length source uses source-driven
  Widevine configuration.
- Android and iOS play through the package's native player
  (`lib/src/native`, `SystemVideoPlayer`), a DRM-capable native player. On phones and tablets it
  shows its own system controls; on Android TV those are turned off and the
  shared `PlayerControls` overlay is stacked over it instead, because the
  plugin's touch-shaped UI cannot be reached with a D-pad. Clear trailer
  sources use no DRM; an authorized feature-length source uses source-driven
  Widevine (Android) or FairPlay (iOS) configuration.
- Every other platform (desktop, web) shows `NoPlayerSurface`. Its copy names
  no platform: nothing that still reaches it has a player implementation.

`isTv` (default `false`) is the host's answer to "is this a TV app". The package
does not probe the form factor. It picks the Android TV route, skips the phone
landscape lock, and sizes the loading spinner and failure alert for TV. Tizen
plays through AVPlay whatever `isTv` says.

`example/` is a runnable loader app that shows
the setup a host needs (storefront, `isTv`, Android lifecycle forwarding).

The package depends on no design system. Its spinner (`PlayerLoadingIndicator`)
and failure alert are package-owned, plain Material on black.

`VideoplayerFeatureBloc` is created before platform policy is resolved — that
is not a guarantee this package makes. On a platform with no player
implementation (desktop, web) the Bloc is still built, but no controller, no
licence client, and no licence HTTP request are created, and the surface never
enters a `failed` playback state. Only the visible result — `NoPlayerSurface`
— is platform-gated; the Bloc's existence is not.

Feature-length sources can receive an optional `WatchProgressRecorder`. The
default composition seeks to `source.progressSeconds` once the duration
is known, writes progress periodically, and records completion; trailer sources
remain playback-only. This package owns the player callback/lifecycle, while
the host supplies the authenticated watch-history client.

On Tizen the resume position is not a seek: it is passed to PlusPlayer as the
`startPosition` player option, which seeks before prepare. Seeking the paused
player straight after initialize failed the hardware decoder on resumed films
(OpenMAX "not data output"). Android still seeks after initialize.

No progress is written until playback sits at its start position. Ticks from
before the resume seek report 0, and recording them overwrote the saved
position, so a failed resume silently came back as "start from the beginning".

## Playback events

`VideoplayerFeatureView.onPlaybackEvent` is an optional
`void Function(PlaybackEvent)`. The package imports no analytics SDK: the host
maps each event onto whatever tool it uses. Without the callback nothing is
observed and the player behaves as before.

```dart
VideoplayerFeatureView(
  videoSource: source,
  onPlaybackEvent: (PlaybackEvent event) {
    switch (event) {
      case PlaybackStarted():
        analytics.track('video_start', event.sourceId);
      case PlaybackSeeked(:final from):
        analytics.track('video_seek', event.sourceId, from, event.position);
      case PlaybackError(:final message):
        analytics.track('video_error', event.sourceId, message);
      default:
        break;
    }
  },
);
```

`PlaybackEvent` is sealed, so a `switch` with no `default` is checked for
exhaustiveness. Every event carries `sourceId`
(`EyzflowSource.id`), the playback `position`, and the `duration`
once the native player knows it.

| Event | When |
|---|---|
| `PlaybackReady` | The native player initialized, before the first frame. |
| `PlaybackStarted` | Once: the first time the player reports playing. |
| `PlaybackPaused` / `PlaybackResumed` | The viewer or the system paused; playback continued. |
| `PlaybackSeeked` | The position was moved. `from` is where it was, `position` where it landed. |
| `PlaybackBufferingStarted` / `PlaybackBufferingEnded` | A stall after the start, and its end. |
| `PlaybackError` | Playback failed. `message` is the text the failure alert shows. |
| `PlaybackAudioTrackChanged` / `PlaybackSubtitleTrackChanged` | The viewer switched track. `language` is the stream's tag; `null` on a subtitle change means off. |
| `PlaybackAdBreakStarted` / `PlaybackAdBreakEnded` | An ad break held the content, and it is over (played, empty, failed or timed out). The content's pause and resume in between are the break's. See [Ads](#ads). |
| `PlaybackCompleted` | Played to the end. Once. |
| `PlaybackClosed` | The player was disposed. Once, always last. |

What a host can rely on:

- One player reports one sequence, ending in `PlaybackClosed`. A player that
  fails before it initializes reports `PlaybackError` and `PlaybackClosed`
  only. Retry on the Android failure alert builds a fresh player, so a new
  sequence begins after the failed one closes.
- Nothing before `PlaybackStarted` is a pause, a stall or a seek: the resume
  seek and the wait for the first frame are startup. The time from
  `PlaybackReady` to `PlaybackStarted` is that wait.
- A stall is never reported as `PlaybackPaused`/`PlaybackResumed`, whichever
  way the native player spells it.
- Each distinct error message is reported once, although the native player
  repeats it on every tick. Startup failures (timeout, a load that throws)
  are reported too.
- After `PlaybackCompleted` only `PlaybackClosed` follows.
- The callback runs synchronously in the player's own listeners: keep it
  cheap. One that throws is logged and ignored. `PlaybackClosed` arrives just
  after the player is disposed, so a callback that touches a `State` must
  check `mounted`.

Where the events come from differs by controls:

- **TV (Tizen, Android TV).** Seeks and track switches are reported by the
  controls overlay as they are issued: a seek's `position` is the requested
  target, and a burst of skips reports the seeks that reached the player, not
  each press. The track a player picks on its own when a film opens,
  including a remembered subtitle language, is not a switch and is not
  reported.
- **Phones and tablets (native controls).** The native UI seeks without
  telling Dart, so a seek is inferred when the position moves more than three
  seconds beyond what playing could explain (backwards, or forwards past
  twice the wall-clock time since the previous tick). A scrub shorter than
  that is missed, and one long drag can report more than one seek. **Audio
  and subtitle switches made in the native controls are not reported**: the
  native player does not surface them.

The rules live in `PlaybackEventEmitter`
(`lib/src/player/playback_event_emitter.dart`), a pure-Dart class fed from
`VideoplaybackSession` ticks by both players and from `PlayerControlsBloc`'s
`onSeeked`/`onAudioTrackChanged`/`onSubtitleTrackChanged` hooks. It is covered
without a player in `test/playback_event_emitter_test.dart`. The example app
lists the events under Play once the player closes.

## Ads

Android, Android TV and iOS (`SystemVideoPlayer`) play the player config's
ad tag through Google IMA
(`interactive_media_ads`). Tizen has no IMA and plays none. The rules are the
web player's (`eyzflow-player`, `src/lib/ad-breaks.ts`).

**Gate.** `PlayerOptions.fromConfig` sets `PlayerOptions.ads` (a `PlayerAds`)
only when `features.ads` is on and `ads.adTagUrl` is not empty
(`PlayerConfig.adTagUrl`). Without it nothing below runs: no manifest read for
markers, no IMA, no ad request. `EyzflowPlayer` makes one `PlayerAds` per
start, and it outlives the player widget, so a fresh player after casting
plays neither the pre-roll nor a played break again.

**Markers** (`lib/src/ads/ad_breaks.dart`). The backend
(`manifest-signal-markers.util.ts`) writes each ad break into every HLS media
playlist as

```
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="eyz-ad-2",START-DATE="1970-01-01T00:00:08.000Z",PLANNED-DURATION=30.000,SCTE35-OUT=0x…
```

so `START-DATE` minus the first `PROGRAM-DATE-TIME` is the position in the
content, and into the MPD as an `urn:scte:scte35:2014:xml+bin` EventStream
(`presentationTime` in its `timescale`). Intro and credits signals
(`CLASS="com.eyzflow.signal"`, `urn:eyzflow:signal`) are skipped here and
read as signals (below). The player loads `master.m3u8`, so `loadHlsMarkers`
(`lib/src/signals/stream_signals.dart`) reads that and its first media
playlist once while the native player starts, for both the ad breaks and the
signals; a manifest that cannot be read counts as a stream without markers.
`parseDashAdBreaks` reads an MPD the same way, for a DASH route.

**Scheduling** (`AdBreakScheduler`, `lib/src/ads/ad_scheduler.dart`, pure
Dart; `ImaAdDriver` does the IMA calls):

- Before the first play the pre-roll plays: on iOS through
  `VideoplaybackSession.beforePlay`, while the content player loads; on
  Android before `session.start()`, so the content player does not yet hold
  the video decoder (a Philips Android TV showed IMA's countdown over a black
  picture otherwise: `MediaPlayer` info 805, video not playing). For a
  mid-roll Android's content player is paused and stopped (`releaseForAd`,
  Media3 `stop()`, which releases the decoder but keeps the item and
  position) and prepared again after the break (`restoreAfterAd`).
- In `beforeContent()` a stream without markers requests the tag and lets
  it decide: a VAST pre-roll, or a VMAP's pre-roll; a VMAP without one lets
  the content start at once and keeps its manager for its own mid-rolls
  (`ContentProgressProvider` gets the content position) and post-roll
  (`contentComplete` when the content ends, before the player closes). The
  wait is outside the 15 s startup timeout; the first `play()` still has it.
- A stream with markers plays a pre-roll only for a marker at ≤ 0.5 s. Every
  other marker is a mid-roll: when a position report lands on or past it,
  having moved forward by at most 2 s since the previous one (the native
  player reports every 0.5 s while playing), the content pauses and the tag
  is requested. A bigger move is a seek, and the breaks it passes are not
  played. Each break plays once.
- After each marker break the ads manager and its container are dropped, so a
  VMAP's own mid-rolls and post-roll never play: at a marker only a VMAP's
  pre-roll plays (cue point 0), and one without a pre-roll gives no ad there.
- The content waits at a break until IMA asks to pause it for the ad, at most
  12 s. An empty or failed tag, an ad error, or no answer in time ends the
  break: the content plays on, with no error shown.
- No break starts while `isAirplayConnected`. While a Chromecast plays, the
  phone's player is not mounted.

**On screen.** `AdLayer` stacks IMA's `AdDisplayContainer` (a platform view)
over the surface and the controls while an ad is requested, playing or (a
VMAP without markers) still scheduled; IMA draws the ad, countdown, skip and
click-through. During a break it takes the input (black under a playing ad, a
spinner while the tag loads); outside one it lets every touch through. On
Android TV the `PlayerControls` overlay is hidden and wrapped in
`ExcludeFocus` during a break, so the remote cannot focus, seek or open a
panel; it keeps its state for after. On iOS the Cast button is hidden.

**Analytics.** The scheduler's break start and end become
`PlaybackAdBreakStarted` / `PlaybackAdBreakEnded` (`PlaybackEventEmitter`),
which `PlaybackEventAdapter` turns into `BeatCollector.beginAd` / `endAd`.
In between the collector ignores the content's state changes and stops its
clocks, so ad time is neither played, paused nor stalled, and a pre-roll does
not count towards video startup.

Covered without IMA in `test/ad_breaks_test.dart`,
`test/ad_scheduler_test.dart` and `test/system_video_player_ads_test.dart`
(a fake `AdDriver` through `SystemVideoPlayer.createAdDriver`). Not tried on a
device with ad break markers yet (Google's sample VAST and VMAP tags on an
iPhone and an Android TV); see the README's known limits.

## Skip intro, recap and credits

The intro, recap, opening and closing credits marked on a stream in the
dashboard (Stream → Signals) are written by the backend into every HLS media
playlist next to the ad breaks:

```
#EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:15.000Z",DURATION=15.000,X-EYZ-TYPE="intro",X-EYZ-LABEL="Main titles"
```

`loadHlsMarkers` reads them with the ad breaks, on every route and with or
without ads (`parseHlsSignals`; `parseDashSignals` reads the MPD's
`urn:eyzflow:signal` EventStream, for a DASH route). A `SignalTracker` in
each player follows the position reports: inside a span (until 0.25 s before
its end; with overlapping spans, the one that started last) it holds that
signal.

- **Phones and tablets** (`SystemVideoPlayer` with the native controls): a
  "Skip intro" / "Skip recap" / "Skip credits" button (`SkipSignalButton`),
  bottom right over the native player. A tap seeks to the span's end, or to
  the end of the content, which ends it. Hidden during an ad break; the ad
  countdown moves up above it when both show.
- **TV** (Android TV overlay and Tizen, `PlayerControls`): while the overlay
  is hidden the button shows as the focused control and holds focus
  (`controls.skipSignal`, in no row), so OK skips. Any other key wakes the
  overlay as before, with focus on the transport; with the overlay up the
  button hides and OK is the focused control's. After a skip, focus goes back
  to the transport. With `controls: false` OK skips while there is a signal
  and plays or pauses otherwise.
- **Events.** Entering and leaving a span is reported as
  `PlaybackSignalStarted` / `PlaybackSignalEnded` (with the `StreamSignal`),
  and `EyzflowPlayer.onSignal` gets the signal, then null. A skip is also a
  `PlaybackSeeked`.
- **Config.** `features.skipButtons: false` hides the button; the events
  still come. `skipButtonTypes` (`intro`, `recap`, `openingCredits`,
  `closingCredits`) picks the types with a button: by default all but the
  closing credits, where skipping only ends the film. The button takes the config's theme: the bar colour and text
  colour, the accent when focused, the radius.
- The dashboard's `label` is passed on (`StreamSignal.label`) but not shown.

Covered in `test/stream_signals_test.dart`,
`test/system_video_player_signals_test.dart` and
`test/tizen_avplay_player_signals_test.dart` (signals through the
`loadSignals` seam). Not tried on a device yet.

## End screen and overlays

`EyzflowPlayer.endScreen` (`EyzflowEndScreen`) is a Netflix-style end screen
from the films the app passes (`EyzflowEndScreenItem`: `streamId`, `title`,
`poster`, `description`, `duration`, `badge`, `sourceType`, `data`), and
`EyzflowPlayer.overlayBuilder` draws the app's own UI instead.

- **Where.** `PlayerOverlayLayer` (`lib/src/end_screen/end_screen_view.dart`)
  wraps the video surface on every route (phones, Android TV, Tizen), from
  the first frame, so the native platform view is never re-parented. It reads
  `PlayerOverlayScope`, which `EyzflowPlayer` puts around the player, and the
  player's `SignalTracker` and position reports (`PlaybackFacts`).
- **When.** From the closing credits signal. A stream without one gets it
  `secondsBeforeEnd` seconds before the end (default 20, 0–120; 0: only when
  the film ends), as at the credits. The last second counts as the end:
  credits that run to the end leave their signal a moment before
  `isCompleted`. `showAt: end`: only when the film ends.
  Not during an ad break. `EndScreenSettings.resolve` puts the app's values
  over the config's `features.endScreen` and `endScreen` section.
- **Full screen.** AVKit's and Android's native full screen cover everything
  Flutter draws, so when the end screen (or the app's overlay) appears the
  player leaves native full screen. At the end of the film the player stays
  open on the end screen instead of closing; without one it closes as before.
  The skip buttons do not leave full screen and are not seen there.
- **Shrinking.** At the credits the surface is resized (not transformed:
  native platform views do not always follow a transform) into the top-right
  corner; a tap on it, or "Back to credits", hides the end screen until the
  end of the film.
- **Up next.** A countdown (`autoplaySeconds`, default 10; 0: none) that
  runs while the credits play or after the end, then picks the next stream.
  Cancel stops it.
- **Picking.** `onSelect(EndScreenSelection)` hears it first;
  `preventDefault()` leaves it to the app. Otherwise `EyzflowPlayer` plays the
  item in place: a new key check, playback session and DRM for its stream
  (`sourceType`, else the same kind as the stream playing). A new `streamId`
  from the app wins over a picked one.
- **TV.** The end screen is its own focus scope with Play focused (or the
  first film without a next stream); the D-pad moves between its buttons and
  films and OK activates. `PlayerControls` leaves focus that is not on its
  own controls or its scope alone, and its skip button stays away while the
  layer shows something (`PlayerOverlayState`).
- **App overlay.** `overlayBuilder(context, PlayerOverlayContext)` is asked at
  a signal or after the end with `signal`, `ended` and `controls` (`skip`,
  `seek`, `play`, `pause`, `dismiss`); a widget it returns wins over the end
  screen. `dismiss()` hides it for that moment.

Covered in `test/end_screen_test.dart` (settings, phases, the phone layer
with shrink, countdown, pick, prevent, cancel and back, the config switch,
the app overlay's precedence, TV focus and Select).

## AVPlay: the single Tizen implementation

AVPlay (`video_player_avplay`, backed by Samsung's plusplayer) is the only Tizen
player implementation for both targets. It replaced
`video_player_videohole`, whose DRM path is broken on Tizen 9.0: attaching any
`DrmConfigs` there breaks segment fetching, even for an unencrypted stream, with
no pssh parsed and no licence request ever issued. Plugin imports are confined
to `tizen_avplay_player.dart` — the view and package barrel
never import `video_player_avplay`.

`VideoPlayer` punches a transparent hole and the native player draws behind
it, so compositing correctness is verifiable only on physical hardware, never
from widget tests or the emulator.

For the current subtitle smoke test, playback selects the first native text
track after initialization and renders AVPlay `subtitleUpdate` events through
`ClosedCaption`. There is intentionally no subtitle picker yet.

## The native player: Android and iOS

The native player (`lib/src/native` with `android/` and `ios/`, based on
`better_native_video_player` 1.5.2, see `doc/native-player.md`) provides its own native controls, which
`SystemVideoPlayer` shows on phones and tablets (`showNativeControls: true`).
On Android TV (`useSharedOverlay: true`) they are turned off and the shared
`PlayerControls` overlay drives playback instead. `SystemVideoPlayer` adapts
the plugin's controller to the same `VideoplaybackController` and
`VideoplaybackTracks` contracts `TizenAvplayPlayer` implements, and reuses
`VideoplaybackSession` unchanged for resume-seek, throttled watch-progress
recording, and finish/error bridging. Imports of `lib/src/native` are confined to
`system_video_player.dart`, mirroring how `video_player_avplay` imports are
confined to `tizen_avplay_player.dart`.

DRM configuration is built by `systemDrmConfigForTarget`
(`system_drm_config.dart`): Widevine on Android, FairPlay on iOS, both using
the source's own license URL(s) and the same `access-token` header
`WidevineLicenseClient` sends on Tizen. Unlike AVPlay, the plugin can attach
that header to its own licence request directly, so there is no Dart-side
licence-fetch callback on this path.

Desktop and web are out of scope: the plugin has no implementation there, so
those platforms continue to show `NoPlayerSurface`.

## HLS only, with Widevine

This section describes the Tizen/AVPlay path specifically — the section
above covers Android/iOS, which take `hlsStreamUrl` through
the native player instead of `avplay.VideoFormat`.

Every target resolves to `EyzflowSource.hlsStreamUrl` and the constant
`avplay.VideoFormat.hls`. There is no format to choose.

HLS is not Apple's private path. Both manifests address the **same** encrypted
segment files with the same `KEYID`s, and the HLS playlists carry an inline
Widevine `pssh` alongside their FairPlay and PlayReady keys — so the licence
this package already acquires unlocks the HLS packaging. Only HLS *signals* a
clear lead-in (`EXT-X-DISCONTINUITY` plus a late `EXT-X-KEY`), which PlusPlayer's
DASH path could not follow: on hardware, DASH played no full-length film and HLS
plays them.

FairPlay is not merely unused, it is inexpressible — the plugin's `DrmType` is
`{none, playready, widevine}`. `EyzflowSource` exposes
`fairplayCertificateUrl` and `fairplayLicenseUrl` for iOS, which plays through
the native player instead.

Films that still fail do so in packaging, not here — see
`docs/superpowers/specs/2026-08-19-flutter-tizen-avplay-widevine-findings.md`
and `scripts/check_stream_packaging.py`.

## The Widevine-only boundary

The AVPlay plugin defines `DrmType.playready`, but **PlayReady is prohibited
everywhere in this codebase.** `drmConfigsForTarget` selects
`DrmType.widevine` only when a feature-length source carries an EYZFlow DRM
credential); clear trailer sources remain
`null`. Nothing in this package constructs a PlayReady configuration.

Tizen DRM playback additionally requires the `drmplay` privilege and a
partner-signed certificate; without both, Widevine licence acquisition fails
on-device even though it succeeds in the widget tests here (which inject
fakes and perform no native playback or network I/O).

## The licence callback blocks the platform thread

AVPlay invokes the Widevine licence callback synchronously on the platform
thread, so `WidevineLicenseClient.fetchLicense` is deliberately minimal: one
bounded POST (15s default timeout), no retry, and no response caching. Never
log DRM challenges, granted licences, certificates, or credentials — a
non-success status is turned into a `WidevineLicenseException` that carries
only the HTTP status code, never the response body.

One deliberate exception, in debug builds only: a *refused* licence's body
(the server's JSON error, capped at 500 characters) is logged, because the
status alone cannot diagnose an EYZFlow failure — the message is what named
the placeholder `storefront-id` behind a 500. `logPlayback` drops these lines
in release builds, so they reach only a developer's console, and the exception
surfaced to the viewer still carries the status alone.

`licenseServerUrl` is deliberately left null. The native licence path hardcodes
its own request headers and cannot carry the `access-token` credential, so the
licence must be fetched from Dart through `licenseCallback`.

## Playback logging

`player_log.dart`'s `logPlayback` prefixes every line with `[videoplayer]` and
uses `debugPrint`, not `developer.log` — `developer.log` output does not reach
the terminal on a Tizen device, while `debugPrint` does. Together with
`TizenDeviceDiagnostics` (which logs model and platform version once per
session) and `WidevineLicenseClient`'s exchange counter, that is the whole
on-device diagnostic surface. Run with `--profile`, not `--release`: the VM
service is what tunnels these lines, and release strips it.

## Test Seam

`VideoplayerFeatureView.playerBuilder` can inject a fake player surface in
widget tests. Runtime code routes Tizen to `TizenAvplayPlayer`, Android TV to
`SystemVideoPlayer` with the shared overlay, Android and iOS phones to
`SystemVideoPlayer` with the plugin's native controls, and every remaining
platform to `NoPlayerSurface`.
Tests use injected fakes throughout; none perform native playback or
real network I/O, so they validate routing, configuration, and lifecycle —
never hardware playback.

Neither real player is ever pumped through `buildDefaultVideoplayerPlayer`
with its own matching `operatingSystem`: both are platform-channel-backed, so
a host test would hit an unmocked `MissingPluginException`. Routing is covered
at the policy level (`player_policy_test.dart`), and each player's lifecycle
through a `VideoplaybackController` fake injected via its `createController`
seam (`tizen_avplay_player_test.dart`, `system_video_player_test.dart`).

## TV player controls

Both TV platforms layer the same controls overlay, `PlayerControls`, over their
player: Tizen over `TizenAvplayPlayer`, Android TV over `SystemVideoPlayer`.
It is driven by `PlayerControlsBloc`, which owns visibility, the auto-hide
timer, playback state, and the track lists — every side effect (play/pause,
seek, track selection) is delegated back through the `VideoplaybackController`
and `VideoplaybackTracks` interfaces, so the overlay never learns which player
is underneath it. Phones and tablets show no overlay; the plugin's own native
controls are the better UI for touch.

The overlay auto-hides four seconds after the last input. A scrub in progress
suspends the countdown outright; an open track panel does not — opening one
restarts the countdown, and a timeout takes the panel down with the overlay
and returns focus to play/pause. It shows:

- a top bar with a back button and the title;
- a centered transport: skip-back 15 s, play/pause, skip-forward 15 s — using
  Material's `replay_10`/`forward_10` glyphs (there is no `replay_15`), with
  the 15 s step carried accurately in the semantic labels, not the icons;
- a bottom bar with elapsed/total time, a scrubbable progress slider (pauses
  on scrub-start, seeks and resumes only if it had been playing, on
  scrub-end), and audio- and subtitle-track pickers. The slider owns its value
  during a drag, so exactly one seek is issued per drag, not one per tick.

Skips only preview. A ±15 s press, and Left/Right on the progress bar
(including key repeats while it is held), moves the shown position at once;
one native seek follows 600 ms after the last press
(`kPlayerSkipCommitDelay`). Holding speeds up: 15 s steps, then 30 s after
four, then 60 s after ten. Every native seek makes the player drop its buffer
and load from the new spot, so seeking on each press kept restarting the
loading and made remote scrubbing slow on Android TV. A drag of the slider
and an explicit seek request still seek at once, and cancel an open burst.

Seeks are serialised in the Bloc: two native seeks are never in flight at
once (PlusPlayer refuses the second one), and a backlog collapses to the
latest target.

### Thumbnail previews

While a skip burst is open or the bar is dragged, the overlay shows the frame
of the previewed time above the thumb, from the stream's WebVTT thumbnail
track (`EyzflowSource.thumbnailsUrl`, `thumbnails/thumbnail.vtt`: a
199×112 tile per 5 seconds, cut from sprite images with `#xywh=`). The track
is loaded once per stream by `ThumbnailLoader.shared`
(`lib/src/core/thumbnails.dart`); the sprites go through Flutter's image
cache. A stream without a track, or one that fails to load, seeks as before.
The tile disappears as soon as the seek is sent. Phones and tablets show none:
their system controls have no place for it.

On Android, seeks land on the nearest keyframe (Media3
`SeekParameters.CLOSEST_SYNC`; a segment start, within about 3 s of the
target with 6-second segments) rather than on the exact time, which needs
decoding a whole segment before the first picture.

### Accessibility labels

Track rows are labelled from the master playlist's `EXT-X-MEDIA`
`CHARACTERISTICS` (RFC 8216 §4.3.4.2.1), fetched once when tracks load,
because neither plugin passes them up. A subtitle carrying both
`public.accessibility.transcribes-spoken-dialog` and
`public.accessibility.describes-music-and-sound` reads "Deutsch (SDH)"; an
audio rendition with `public.accessibility.describes-video` reads
"Deutsch (AD)". An audio rendition's `CHANNELS` (§4.3.4.1, first parameter:
independent channel count) adds "5.1" for `6` and "7.1" for `8`, so the
stereo and surround mixes of one language no longer share a name. Native tracks are matched to renditions by language and
occurrence order. A failed fetch leaves the plain language names.

On Android TV the overlay is a `Stack` from the first frame with the native
surface always at index 0. Re-parenting `NativeVideoPlayer` when the controls
appear disposes its platform view, while the plugin controller keeps
addressing the old view id, so every view-routed call (subtitle tracks, track
selection, dispose) fails with `NO_VIEW`.

A buffering spinner sits beside the elapsed time while the overlay is up, so
it never overlaps the transport. Once the overlay has finished fading out it
moves to the centre of the screen, where a stall is still visible with no
elapsed time to sit beside.

Both the move and the focus reset to play/pause wait for the fade to finish
rather than firing when the state flips — either one during the fade is seen
as a jump across a still-visible overlay.

### TV remote mapping

The same mapping serves the Samsung remote and an Android TV D-pad. Key
handling follows the `flutter-tizen-tv-remote-input` pattern
(`FocusableActionDetector`/`Focus`, not raw key listeners):

- OK (`select` and `enter`) activates the focused control. While the overlay
  is hidden during an intro, recap or credits, that is the skip button.
- Back (`goBack` and `escape`) closes an open track panel first, then hides a
  visible overlay, then pops the player.
- Media keys drive playback directly: `mediaPlay`/`mediaPause`/`mediaPlayPause`
  toggle play/pause, `mediaFastForward`/`mediaRewind` skip forward/backward.
- Arrows never scrub on their own. While the overlay is hidden they only wake
  it, on the transport; while it is visible they belong to the row model (see
  below). Scrubbing is the progress bar's, reached by focusing it.
- Any other key wakes the overlay and resets the auto-hide timer.
- `audioVolume*` and `power` are never intercepted — they always reach the
  system.

### Subtitle memory

`SubtitlePreferenceStore` remembers the viewer's most recent subtitle language
in memory for the app-process lifetime, across films within one session —
never persisted across app restarts. It lives on a package-owned `get_it`
locator, registered via `setupSubtitlePreferenceStore` (mirroring the
`TizenDeviceDiagnostics` pattern), so the package never depends on the
app-wide locator; a host that never calls `setupSubtitlePreferenceStore`
simply gets no subtitle memory.

When a new film's tracks load: a remembered "off" clears subtitles, a
remembered language with a matching text track selects it, and a remembered
language with no matching track selects nothing — that is the product rule,
never the plugin's auto-picked default.

### Intentionally absent

Playback-speed selection and mute are not implemented — out of scope per
product direction, not an oversight. Casting is on phones and tablets only
(see "Chromecast and AirPlay" in the README); the TV routes have none.

### Feature-level Close button

`VideoplayerFeatureView` hides its shared top-left Close button on Tizen; the
controls overlay owns Back (closing a panel, then hiding, then popping), so a
second always-visible close affordance would be redundant. Every other
platform keeps the shared Close button unchanged.

## Verification

From the package root:

```bash
flutter-tizen pub get
flutter-tizen analyze
flutter-tizen test
```

## Logging

Filter the console by `[eyzflow-streaming]`. Source preparation includes the full, unmodified stream URL. Progress PUT logs distinguish attempt, confirmed success, cancellation and failure, including debug position/completion and elapsed time. Raw SDK errors and stacks are not logged.
Verbose lifecycle/details are debug-only; sanitized actionable failures remain
available in release. Never pass credentials, receipts, personal data or raw
payloads to logging helpers. Full stream URLs (including signed query strings)
are an explicit debug-only exception for playback debugging; treat debug logs as
sensitive. URL log statements are guarded by `#if DEBUG` on Apple and
`if (kDebugMode)` on Flutter, not emitted in release builds.

## Localization

Player controls, dialogs and playback errors are localized in this package
(`lib/src/l10n`, `gen_l10n`) through `streamingL10n`, in
`eyzflowPlayerLanguage` (set by `EyzflowPlayer(language:)` or
`setEyzflowPlayerLanguage`, else the device's language), falling back to
English. After editing an ARB, run `flutter gen-l10n` here and commit
`lib/src/l10n/generated`.

Track language names come from `EyzflowLanguageNames`
(`lib/src/l10n/language_names.dart`): a table generated from the Unicode CLDR
display names for the two-letter codes and their regional variants, in the
player's four languages, plus the ISO 639-2 aliases (`deu`, `ger` → `de`).
Lookup order: the exact code, without its region, the alias, an English
language name, the code itself. Apps can set `EyzflowLanguageNames.resolver`.

## Fullscreen orientation

Android phone playback requests landscape for the player route and releases
the orientation preference when the route closes (including Back and errors).
Tablets and TVs retain their device orientation. Playback hides status and navigation bars;
closing the player restores them. Video keeps its aspect ratio, so cinematic
letterboxing is expected.

### Android visible playback

Android uses the package's own native player. Its
Activity coordinator owns audio focus, visibility, MediaSession, and PiP.
Phone/tablet playback may continue in PiP; Android TV disables film PiP. Hidden
playback and screen lock pause immediately, and returning stays paused until
Play. There is no background playback foreground service.

The app supplies title/artwork and route eligibility. Native pause and PiP-close
events checkpoint the latest position without marking a film completed; only
natural end completes watch history. Closing PiP closes the player route. The
Android failure dialog offers an explicit Retry with a fresh controller.
Startup intent is versioned so delayed loading cannot undo a later pause.
Captions retain the selected track in PiP, using native subtitle rendering.

Flutter Apple release bundles are outside this project's release scope; these
Android lifecycle changes do not add Apple behavior. Tizen keeps its existing
playback adapter and controls.
