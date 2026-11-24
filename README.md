# eyzflow_player

The EYZFlow video player for Flutter apps, in one package:

- **The player:** fullscreen playback of EYZFlow streams. AVPlay on Samsung
  Tizen TVs, ExoPlayer on Android and Android TV, AVPlayer on iOS; Widevine and
  FairPlay DRM; the TV controls overlay; subtitles and audio tracks; resume and
  watch progress. How it works: [doc/player.md](doc/player.md).
- **The EYZFlow rules around it,** the same as the EYZFlow web
  player:
  - **Player key check:** `POST /v1/player/license`, renewed while playing.
  - **Stream and device limits:** a playback session that opens, heartbeats
    and closes, with `STREAM_LIMIT` / `DEVICE_LIMIT` refusals shown to the
    viewer.
  - **Playback quality analytics:** cumulative beats to `POST /v1/player/beat`
    (startup time, played, paused and stalled time, stalls, seeks, errors).

## Use

```dart
import 'package:eyzflow_player/eyzflow_player.dart';

Navigator.of(context).push(MaterialPageRoute<void>(
  fullscreenDialog: true,
  builder: (_) => EYZFlowPlayer(
    streamId: streamId,                       // not the catalogue id
    title: title,
    sourceType: EYZFlowFilm(catalogueId),     // or EYZFlowTrailer(…)
    progressSeconds: resumeAt,
    isTv: isTv,
    drmAuthorization: 'Bearer $cognitoAccessToken',
    storefrontId: storefront.id,
    drmParameters: const {'source': 'internal'},
    offerId: offer.id,                        // royalties: see below
    playerKey: 'pk_…',                        // optional
    configId: 'cfg_…',                        // optional: dashboard player config
    watchProgressStore: myWatchHistory,       // optional: see below
    language: 'de',                           // optional: en, de, fr, nl
    onLimitReached: (limit) => …,             // STREAM_LIMIT, DEVICE_LIMIT, …
    onLicenseError: (error) => …,             // PLAYER_KEY_INVALID, …
    onPlaybackEvent: (event) => …,            // the host's own analytics
  ),
));
```

Pass the viewer's `Authorization` and the storefront, and the player builds the
DRM `access-token` header itself.

`VideoplayerFeatureView(videoSource: …)` is still exported: the player alone,
with no key check, session or beats, and a ready-made `drmAccessHeader`.

### What happens

Before playback, in the web player's order:

1. Reads this device's id (`shared_preferences`, key `eyzflow.deviceId`).
2. With a `playerKey`: the key check, sending the app (`{platform, id}`) in
   place of a web page's Origin. A refusal shows the error screen and calls
   `onLicenseError`. If the check cannot be made, playback goes on without a
   token and without analytics.
3. With `drmAuthorization` and `storefrontId`: opens a playback session with
   `platform` (`android`, `androidtv`, `ios`, `tizen`) and `X-Device-Id`, for
   a trailer too (it says whether the viewer's plan plays ads, see
   [Ads](#ads)), so trailers count against the plan's stream limit. A limit
   shows the error screen and calls `onLimitReached`. Any other failure
   carries on; the DRM licence request enforces the limits too.
4. For a film: builds the `access-token`: `authorization` plus
   `storefront_id`, `device_id`, `playback_session_id` and `player_token`,
   with any `drmParameters`.

While playing: the token renews after `refresh_after` (a refusal stops playback
only when the organisation enforces), the session heartbeats at the interval
the backend gives (a session ended elsewhere stops playback with
`PLAYBACK_SESSION_ENDED`), and beats go out every heartbeat interval, at once on
the first frame and on errors, and when the app goes to the background. On
close: a final beat and `DELETE` of the session.

Without `playerKey` there is no key check and no beats. Without `storefrontId`
(or `drmAuthorization`) there is no session. A trailer plays without DRM.

### Viewer messages

The player's own copy (controls, playback errors) is localized in en, de, fr
and nl (`EYZFlowPlayer(language:)` or `setEYZFlowPlayerLanguage`, else the
device's language). Track names in the TV audio and subtitle panels come from
a built-in table (Unicode CLDR) in the same language: "Deutsch" for `de`,
`deu`, `ger` or `de_DE`; set `EYZFlowLanguageNames.resolver` to use your own.
The limit and key messages are the web
player's, in English; replace the error screen with `errorBuilder` to show
your own (the failure carries its code).

| Code | Message |
|---|---|
| `STREAM_LIMIT` | You're watching on too many screens. Stop playback on another device to watch here. |
| `DEVICE_LIMIT` | Your plan's device limit is reached. Remove a device in your account to watch here. |
| `DEVICE_REVOKED`, `SESSION_REVOKED` | You were signed out on this device. Sign in again to watch. |
| `PLAYBACK_SESSION_ENDED` | Playback was stopped from another device. |
| `PLAYER_KEY_INVALID` | This player is not set up correctly (invalid player key). |
| `DOMAIN_NOT_ALLOWED`, `APP_NOT_ALLOWED`, … | This video cannot be played in this app. |

### Playback events

`onPlaybackEvent` reports what playback does: ready, started, paused, resumed,
seeked, buffering started/ended, error, audio/subtitle track changed, ad break
started/ended, completed, closed. The beats are computed from them; a host can also send them
to its own analytics. Rules and limits: [doc/player.md](doc/player.md#playback-events).

### Chromecast and AirPlay

On Android and iOS phones and tablets, a **Cast** button appears once a
Chromecast is found on the Wi-Fi: inside the native controls on Android (it
fades with them), top right on iOS. Picking a TV hands the film over at the
phone's position; the phone shows the poster, "Playing on …", play/pause, a
seek bar and **Stop casting**, which hands playback back at the TV's position.
The TV selects the phone’s current audio and subtitle languages when matching
tracks are available. Subtitles turned off on the phone stay off on the TV.
The casting screen’s Audio and Subtitles panels switch tracks on the TV.
Audio labels show 5.1, 7.1 and AD when the receiver identifies the rendition.
When casting ends, the phone resumes with the TV’s last reported languages
where available, including subtitles off. If the receiver disconnects before
confirming a selection, the phone restores its outgoing choices. Long track
lists scroll, and disconnecting closes any open casting panel.
Closing the player stops the TV too. If the TV refuses the film, the phone
says so and plays on.

While the TV plays, the playback session keeps heartbeating (the film counts
as the phone's one stream: the TV's licence request carries the phone's
`device_id` and `playback_session_id`), beats keep counting played, paused and
stalled time, `onPlaybackEvent` reports the TV's states, and watch progress is
recorded. The cast clock holds its position during buffering and while a seek
awaits the next receiver status.

**Films need the EYZFlow Cast receiver** (`cast-receiver/`): Google's standard
receiver cannot add the DRM `access-token` to licence requests. EYZFlow hosts
it at `https://stream.eyzflow.com/cast/index.html` as app id `A534F914`, which
the player uses when neither `castReceiverAppId` nor the config's
`cast.receiverAppId` names another receiver. See
[cast-receiver/README.md](cast-receiver/README.md).

**AirPlay** is the iPhone's own: Apple's player controls show the AirPlay
button, and FairPlay keys for the Apple TV are requested by the phone.

Casting uses the Chromecast client in our copy of the native player (CASTV2
over the local network, no Google Cast SDK). Turn it off with
`enableCast: false`, or with `features.chromecast: false` in a player config.

### Ads

On Android, Android TV, iOS and Tizen the player plays ads from the player config:
`features.ads` on **and** a non-empty `ads.adTagUrl` (a VAST or VMAP tag).
Otherwise no ad request is made at all.

For a storefront viewer (`drmAuthorization` and `storefrontId`) the plan
decides too: the playback session, answered before the player loads, says
whether the plan plays ads for the title (`ads`: true when the plan requires
ads or the product is AVOD or FAST). `ads: false` plays no ads at all, no
pre-roll and no mid-rolls at the markers. When the session says nothing (no
session, an older backend, a failed request), the config decides as above.
The session's `ad_targeting` (e.g. `plan=basic-ads`, `access=svod`) is added
to the tag's `cust_params`; a key the tag already sets there keeps the tag's
value. A plan with ads cannot turn on ads the config has off.

On Android, Android TV and iOS ads play through Google IMA
(`interactive_media_ads`), which shows the ad, its countdown, the skip button
when the ad allows one, and the click-through. There is no IMA for Tizen, so
there the player reads the tag itself and plays the ads in AVPlay:

- VAST 2–4 inline and wrapper ads (up to 5 wrappers in a row), ad pods in
  their sequence, and a VMAP's breaks (`start`, `end`, a time or a
  percentage). Linear ads only: companion, overlay and VPAID creatives are
  skipped. Of an ad's media files it plays an MP4 (the tallest up to 1080p),
  else HLS.
- The impression, `start`, quartile, `complete`, `skip` and `progress`
  tracking URLs, and the error URLs with `[ERRORCODE]` (e.g. 303 no ad, 402
  media timeout, 403 no media a TV plays, 405 media failed).
- On screen: "Ad 1 of 2 · 0:12" over the ad and, for an ad with a
  `skipoffset`, "Skip in 3" and then a Skip button that takes the remote's
  focus, so OK skips. Back leaves the player as from the controls. No
  click-through on a TV.
- An ad that does not start within 10 s, stalls for 10 s or fails is
  reported and the next one plays.

When ads play follows the ad break markers on the stream (dashboard: Stream →
Signals → Ad break), which the backend writes into the manifests as SCTE-35.
The player reads them from the HLS playlist it loads (`EXT-X-DATERANGE`), the
same rules as the web player:

- **Stream with markers: the markers win.** A marker at the start is a
  pre-roll; every other marker is a mid-roll, requested from the tag when
  playback reaches it, and played once. A marker passed by seeking (or by
  resuming further on) does not play. A VMAP tag's own schedule is dropped
  after each break: at a marker only its pre-roll plays, so a VMAP without one
  gives no ad there. **Streams with markers need a VAST tag.**
- **Stream without markers: the tag decides.** It is requested once before the
  content starts: a VAST gives a pre-roll, a VMAP its own pre-roll, mid-rolls
  and post-roll.
- Android: the pre-roll plays before the film's player loads, and during a
  mid-roll the film's player lets go of its video decoder (it reloads at the
  same position afterwards). TVs often have one hardware decoder, and while
  the film holds it the ad shows no picture, only IMA's countdown. iOS loads
  the film while the pre-roll plays.
- Tizen: the pre-roll plays before the film's player is created, and for a
  mid-roll or post-roll the film's player is paused and deactivated (its
  video decoder freed, PlusPlayer `Deactivate`) before the ad's own player
  starts, and activated again after the break.
- At a break the content waits until the ad starts, or until it turns out
  there is none (empty or failed tag, ad blocker, no answer within 12 s):
  then it plays on, with no error.
- During an ad the player's controls are hidden and out of reach (on Android
  TV the remote cannot focus or seek them), the iOS Cast button is hidden, and
  playback analytics leave the ad time out: no played, paused or startup time.
  `onPlaybackEvent` reports `PlaybackAdBreakStarted` and
  `PlaybackAdBreakEnded` around it.
- No ads start while the video plays on AirPlay or a Chromecast. When casting
  hands playback back, the pre-roll and the breaks already played do not play
  again.
- **Countdown before a mid-roll** (`features.adCountdown`, on when missing):
  a small corner notice, "Ad in 5" … "Ad in 1", for the last seconds before a
  mid-roll: `ads.countdownSeconds` long (whole seconds, 1–30; missing or not a
  number means 5, others are rounded and clamped), in the player's language (en, de, fr, nl; English otherwise). It
  counts down to the stream's markers, else to a VMAP's mid-roll cue points
  (never a pre-roll or post-roll). A marker passed by seeking counts down
  again when playback nears it later; a VMAP cue point played through does
  not after a rewind. It hides while paused, buffering or seeking, during an
  ad, on AirPlay, and once the viewer seeks past the break. It takes no touch
  or focus; on Android TV it stays up while the overlay is hidden.
  `false` turns it off; an inline `config` change to either field applies
  without reloading the stream.

Host setup for ads: see step 7 under [Host setup](#host-setup). The example app
has an **Ad tag URL** field to try a tag without a config (Google's sample
tags: <https://developers.google.com/interactive-media-ads/docs/sdks/html5/client-side/tags>).

### Player configs

`configId` loads a player config from the dashboard (Player → Configs) with
`GET {api}/v1/player-configs/{configId}`, as the web player does. The endpoint
is public (no auth) and the backend caches it for 60 s; the player keeps each
loaded config in memory for the life of the app. It is loaded before the key
check and playback start, and the player waits at most 5 s for it: an
unknown id, an error or no network plays with the player's defaults and shows
nothing to the viewer.

`config: PlayerConfigOverride(…)` is the web player's inline `config` prop:
what it gives wins over the remote config. Theme and features merge field by
field, `cast` and `ads` replace the remote ones, `drm.parameters` merge.
`drmParameters`, `storefrontId` and `castReceiverAppId` given in code win over
the config's.

What each field does on each app route (phones are the native controls on
Android and iOS; Android TV and Tizen use the player's own TV overlay):

| Field | Phones | Android TV | Tizen |
|---|---|---|---|
| `theme.accentColor` | – | focused control (the skip button too), progress bar | same |
| `theme.textColor` | skip button text | title, times, icons, track rows | same |
| `theme.backgroundColor` | – | audio/subtitle panel | same |
| `theme.controlsBarColor` | skip button | shade behind the controls | same |
| `theme.borderRadius` (px) | skip button | track rows, focused progress bar, skip button | same |
| `features.controls` | – (the native controls hold Close) | false: no overlay; Back closes, OK plays/pauses, left/right and media keys skip | same |
| `features.autoHideControls` | – | false: the overlay stays up | same |
| `features.captions` | – (the native menu offers subtitles) | false: no subtitles, none offered | same |
| `features.loop` | yes | yes | – (AVPlay's player cannot loop) |
| `features.chromecast` | false: no Cast button | (TVs never cast) | (TVs never cast) |
| `features.airplay` | iOS: false keeps the video off AirPlay | – | – |
| `features.pip` | Android: false turns picture-in-picture off (iOS has none) | (off on TV) | – |
| `cast.receiverAppId` | the receiver films cast to, when `castReceiverAppId` is not set | – | – |
| `features.ads`, `ads.adTagUrl` | ads through Google IMA, see [Ads](#ads) | same | ads played by the player itself, see [Ads](#ads) |
| `features.adCountdown` | false: no "Ad in 5" notice before a mid-roll | same | same |
| `ads.countdownSeconds` | the notice's length, 1–30 s (default 5) | same | same |
| `features.skipButtons` | false: no "Skip intro / recap / credits" button (the signal events still come) | same | same |
| `skipButtonTypes.*` | `intro`, `recap`, `openingCredits`, `closingCredits`: which signals get a skip button (default: all but closing credits) | same | same |
| `features.endScreen`, `endScreen.*` | false: no end screen; `autoplaySeconds` (0–30), `showAt` (`credits`/`end`), `shrinkVideo`, `secondsBeforeEnd` (0–120, without closing credits) tune it | same | same |
| `drm.parameters` | into the DRM `access-token`; `storefront_id` also opens the playback session | same | same |

Not honoured anywhere in the apps:

- `features.autoPlay`: the app player opens on the viewer's Watch tap and
  always starts.
- `features.muted`: no app route has an unmute control (Media3's controls,
  the TV overlay), so a muted film would stay silent.
- `features.qualitySelector`: the app players have no quality menu.
- `cast.androidReceiverCompatible`, `cast.autoJoinPolicy`: options of the
  web Cast SDK.
- `isProtected`: the source type decides (`EYZFlowFilm` plays with DRM).

Without a config (or when it cannot be loaded) the TV overlay keeps its own
white-on-black look; the dashboard's default purple applies only when a
config is loaded or an inline `theme` is given. The backend stores no `drm`
section today, so `drm.parameters` (and a storefront in it) come only from an
inline config.

`PlayerConfigClient`, `PlayerConfig` and `mergePlayerConfig` are exported for
hosts that want the config themselves (`lib/src/core/player_config.dart`).

### Headless

The pieces are exported for hosts that drive playback themselves:
`PlayerLicenseClient` / `PlayerLicenseSession`, `PlaybackSessionClient`,
`buildAccessToken`, `BeatCollector` / `BeatTransport` / `HttpBeatSender`,
`PlaybackEventAdapter` and `PlaybackCoordinator`. The code under
`lib/src/core` imports no Flutter.

## End screen

Pass the films; the player shows them Netflix-style at the closing credits
(the video shrinks into a corner) or after the film, counts down to the next
stream and plays a picked one in place:

```dart
EYZFlowPlayer(
  streamId: episode.streamId,
  title: episode.title,
  endScreen: EYZFlowEndScreen(
    nextUp: EYZFlowEndScreenItem(streamId: next.streamId, title: next.title, poster: next.poster),
    items: [
      for (final f in similar)
        EYZFlowEndScreenItem(streamId: f.streamId, title: f.title, poster: f.poster, duration: f.length),
    ],
    onSelect: (selection) => router.replaceWatch(selection.item.streamId),
  ),
)
```

`onSelect` can call `preventDefault()` to handle the pick itself.
`itemBuilder` draws a film your way, `title` renames the row, and the
config's theme styles it. On TV it takes the remote's focus. For a layout of
your own, `overlayBuilder` is asked at each signal and after the end, and
wins when it returns a widget. See [doc/player.md](doc/player.md#end-screen-and-overlays).

## Layout

```
lib/eyzflow_player.dart      the public API
lib/src/videoplayer_feature.dart, bloc/, player/, l10n/
                             the player
lib/src/core/                key check, sessions, access token, beats, player
                             configs (pure Dart)
lib/src/flutter/             EYZFlowPlayer, the coordinator, the error screen
lib/src/native/, android/, ios/
                             the native player for Android and iOS, based on
                             better_native_video_player (MIT, see
                             THIRD_PARTY_LICENSE_better_native_video_player)
doc/player.md                how the player works
example/                     loader app
```

The package has no dependency on any EYZFlow app code: the app passes in what
it owns (the viewer's token, the storefront, where watch progress goes).

### Watch progress

Films report their position (every 10 seconds, on pause and at the end) to a
`WatchProgressStore` the app provides, for example its watch-history client:

```dart
final class MyWatchHistory implements WatchProgressStore {
  @override
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  }) => api.saveProgress(catalogueId, progressSeconds, completed);
}
```

A failed save is logged and never interrupts playback. Trailers record
nothing.

### Royalties

Licensor royalties are counted from the seconds viewers watch. With
`offerId` (the film or episode played), `drmAuthorization` and a storefront,
the player reports them itself to
`POST /v1/content/storefront/{storefrontId}/playback-events`: every 30
seconds while the film plays, at once on a pause, at the end and when the app
goes to the background, and a last time when the player closes. Only time
spent playing the film counts: not ads, pauses, seeks or stalls. Each report
carries the seconds since the previous one (at most 120) and one session id
per playback; seconds a report could not deliver go with the next one. The
film's catalogue id goes with it.

Trailers, and a film the end screen picked, report nothing. It works with or
without a player key and analytics, on every platform (Tizen included). An
app that sends these events itself should stop once it passes `offerId`, or
the seconds are counted twice. `usageSender` replaces the upload, e.g. to log
reports in a test app.

## Host setup

1. Optionally set the player's language (`EYZFlowPlayer(language:)`, or
   `setEYZFlowPlayerLanguage` before building a `VideoplayerFeatureView`);
   without it the device's language is used when the player has it.
2. Pass `isTv`. The package does not detect the form factor. On Android it
   picks the D-pad overlay and the `androidtv` platform; Tizen always plays
   through AVPlay.
3. Android: forward the activity lifecycle and picture-in-picture callbacks to
   `com.eyzflow.player.playback.AndroidPlaybackHost` (see
   `example/android/.../MainActivity.kt`). The native player only plays while the host reports the activity
   visible. `minSdk` 25 and the `INTERNET` permission; a leanback launcher
   entry for Android TV.
4. Tizen: the `internet` and `drmplay` privileges in `tizen-manifest.xml`, and
   a partner-signed certificate for DRM. Add `shared_preferences_tizen` and
   `package_info_plus_tizen` (or pass `deviceIdStore` and `appId`); without
   them the device id lasts for the process only, so the device limit counts
   the TV again after each restart.
5. iOS: deployment target 15.0, and for finding Chromecasts these Info.plist
   keys (iOS asks the viewer for local network access on the first scan):

   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>Finds Chromecast devices on your Wi-Fi so you can watch on your TV.</string>
   <key>NSBonjourServices</key>
   <array><string>_googlecast._tcp</string></array>
   ```

   Android needs nothing extra: the multicast permission comes with the
   package.
6. Player key from an app: add each app to the key's "Allowed apps"
   as platform plus package name; matching is exact, so the Android TV build
   needs its own `androidtv` entry next to `android`.
7. Ads (Google IMA): Android apps need core library desugaring, as in
   `example/android/app/build.gradle.kts` (the `ACCESS_NETWORK_STATE`
   permission IMA wants comes with the package):

   ```kotlin
   android {
       compileOptions { isCoreLibraryDesugaringEnabled = true }
   }
   dependencies {
       coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
   }
   ```

   Without it the Android build fails, whether ads are used or not. iOS needs
   nothing extra.

`endpoints` moves the key check, sessions and beats (for a dev backend). Stream
and DRM licence URLs come from `EYZFlowSource` and stay on production, so a dev
session id would not match the production licence gate.

## Known limits (v1)

- No bitrate, quality switch or dropped frame figures: the native players do
  not report them yet. Beats send `null` and 0.
- The position between state changes is estimated (last reported position plus
  time played), because the players report a position only with each event.
- The player token in the DRM header is the one from the start of playback:
  the native players take headers once. VOD licences are requested at start.
- Track changes made in the phone's native controls are not reported.
- Player configs: the fields and routes marked "–" in
  [Player configs](#player-configs) are not honoured, and nothing re-reads a
  config while a film plays. The theme and the AirPlay switch are not tried on
  a device yet.
- Casting: subtitles and audio tracks cannot be switched from the phone while
  the TV plays (the TV plays the default tracks), and a phone that leaves the
  Wi-Fi loses control of the TV. Not tested on a real Chromecast yet.
- FairPlay (iPhone, AirPlay) was rewritten to Apple's standard flow and is not
  tested on a device yet.
- Limit and key messages are English only.
- Ads: tried with Google's sample VAST and VMAP tags on an iPhone (pre-roll,
  mid-roll, post-roll) and a Philips Android TV (pre-roll, mid-roll); not on
  an Android phone, and not with ad break markers (no stream had any yet).
  After an Android mid-roll the film rebuffers for a few seconds. On Android
  TV the skip button may not be reachable with the remote (IMA's own view;
  the plugin has no TV focus handling); the sample ads were not skippable.
  There is no "ad in 5 s" notice before a mid-roll. The marker's planned pod length is not sent to the ad server: the
  tag decides the pod. Companion and overlay (non-linear) ads are not handled.
  While a VMAP on a stream without markers waits for its next break, IMA's
  container stays over the content (it lets touches through).
- Ads on Tizen: covered by tests only, not tried on a Samsung TV yet. Whether
  every model hands the decoder to the ad's player after the film's player is
  deactivated, and gets it back, is the thing to check on hardware; a model
  that refuses fails the ad (reported with 405) and resumes the film.

## Develop

Needs Flutter ≥ 3.41.9.

```sh
flutter pub get
flutter analyze
flutter test

cd example
flutter run                     # Android phone/tablet, Android TV, iOS
flutter-tizen run -d <device>   # Samsung TV
```

After editing an ARB file in `lib/src/l10n`, run `flutter gen-l10n` and commit
`lib/src/l10n/generated`.

The example app plays a stream with a bearer token, storefront and optional
player key, and logs every playback event, beat, limit and refusal.

## Licence

MIT, see `LICENSE`. The native player for Android and iOS (`lib/src/native`,
`android/`, `ios/`) is based on
[better_native_video_player](https://pub.dev/packages/better_native_video_player),
also MIT: `THIRD_PARTY_LICENSE_better_native_video_player`.
