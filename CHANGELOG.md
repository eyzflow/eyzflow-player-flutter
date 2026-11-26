## 0.8.4

- Android TV play/pause (EYF-513): the play/pause button no longer shows
  Play for a moment after each seek. It follows the viewer's intent; only a
  pause, the end of the film or an error turns it to Play.

## 0.8.3

- TV seeking (EYF-511): while the viewer seeks with the seek bar or FF/RW,
  the back, play/pause and forward buttons in the middle fade out so the
  frame they are looking for is clear, and come back once the seek is made.
  Pressing the middle back or forward button itself keeps them up.
- TV start (EYF-512): a film opens without the controls overlay, and
  without play/pause flipping from Play to Pause; only the spinner shows
  while it loads. The first key press brings the controls up on
  play/pause. With `autoHideControls: false` they are up from the start,
  as before.

## 0.8.2

- Seek thumbnails (EYF-505): every sprite of a film's thumbnail track now
  downloads once, as soon as the track loads, and stays for that film, so
  seeking no longer fetches images and previews show without a wait. Only a
  few sprites are decoded at a time, to keep memory low on TVs. Each tile is
  cut out of its sprite pixel for pixel, so the thin line from the tile above
  (or beside it) no longer shows on the preview.
- TV seek bar (EYF-506): OK on the focused seek bar plays and pauses. After
  Left or Right, OK seeks to the previewed point at once instead of waiting
  for the skip delay, and leaves play/pause as it was.

## 0.8.1

- Cast button on iOS (EYF-495): the button no longer sits on AVKit's top bar
  over the volume control. It is now a native round button, the same size as
  AVKit's, under the trailing end of that bar and lined up with the volume
  button, in portrait, landscape and on iPad. It follows AVKit when the bar
  moves with the safe area (after a rotation). Hidden during ad breaks, as
  before; iOS 15 and later. Android's Cast button is unchanged.

## 0.8.0

- Watch progress (EYF-493): the player saves the viewer's place in a film to
  the EYZFlow watch history itself
  (`PUT /v1/content/storefront/{storefrontId}/watch-history`), with the
  viewer's `drmAuthorization`, the storefront and `offerId`, so apps no longer
  need their own `WatchProgressStore`. An app's own `watchProgressStore` still
  replaces it; `saveWatchProgress: false` saves nothing. Without the viewer's
  authorization or a storefront nothing is sent. New: `EYZFlowWatchHistoryStore`.
- A save counts as completed once the position reaches the player config's new
  `watchProgress.completedPercent` of the film (50–100, default 95; 100 means
  only the end), not only at the very end. `WatchProgressRecorder.report` and
  `checkpoint` take an optional `duration` for it.
- A film opened and closed straight away no longer shows in "Continue
  watching": the first save is never one at 0 seconds that is not completed.
  The same save twice in a row is sent once.

## 0.7.1

- Chromecast tracks (EYF-480): the phone's audio and subtitle languages are
  sent to the TV once it plays. Sent while it still loaded, they were lost
  because the receiver goes back to its default tracks when the film starts.
  Stopping while the TV still loads keeps the phone's own choice.

## 0.7.0

- Chromecast tracks (EYF-480): casting starts the TV with the phone's audio and
  subtitle languages, and subtitles turned off on the phone stay off. The
  casting screen has Audio and Subtitles panels that switch tracks on the TV
  (with 5.1, 7.1 and AD labels where the receiver names them), and changes made
  with the TV's own remote menu show on the phone. When casting ends, the phone
  resumes with the TV's last languages. The cast clock and watch progress move
  between the receiver's reports and hold while it buffers or seeks.
- Cast receiver (EYF-476): on a TV with a remote, Up or Menu opens a Subtitles /
  Audio menu over the film (`cast-receiver/index.html`, hosted at
  `https://stream.eyzflow.com/cast/index.html`; not part of the package).

## 0.6.3

- Chromecast (EYF-479): with no `castReceiverAppId` and no `cast.receiverAppId`
  in the player config, films now cast through the EYZFlow receiver
  (`A534F914`) instead of offering no Cast, and trailers no longer go to
  Google's default receiver. An app or config that names its own receiver
  keeps it. Matches the web player 0.9.1.

## 0.6.2

- Subtitles on Tizen (EYF-467): the controls' bottom bar no longer covers the
  subtitles. While the controls show, the subtitles move up above the progress
  bar and track buttons, and drop back when they hide.

## 0.6.1

- Playback sessions (EYF-466): the heartbeat and the close no longer send
  `Content-Type: application/json` without a body. The API refused them (400),
  so sessions went stale and a closed player kept counting against the plan's
  stream limit.

## 0.6.0

- Removed (EYF-225): the deprecated `Eyzflow…` aliases from 0.5.0
  (`EyzflowPlayer`, `EyzflowSource`, `setEyzflowPlayerLanguage` and the
  rest). Use the `EYZFlow…` names.
- Ads on Tizen (EYF-216). There is no IMA for Tizen, so the player reads the
  config's ad tag itself and plays the ads in AVPlay, with the same rules as
  the other platforms: the stream's ad break markers, the viewer's plan, the
  "Ad in 5" countdown, and ad breaks in the playback events.
  - VAST 2–4 inline and wrapper ads, ad pods, and VMAP pre-rolls, mid-rolls
    and post-rolls; MP4 (up to 1080p) or HLS media.
  - Impression, quartile, complete, skip, progress and error tracking.
  - "Ad 1 of 2 · 0:12" over the ad and a Skip button for skippable ads,
    reachable with the remote.
  - The film's player hands its video decoder to the ad's player for a
    mid-roll or post-roll, and the pre-roll plays before the film loads.
  - New dependency: `xml`.
- Skip buttons on Tizen (EYF-214): after OK on "Skip intro" (or recap,
  credits) the button no longer comes back for a few seconds. AVPlay reports
  the skip's target as soon as the seek is sent, then the old position until
  PlusPlayer lands; a skipped signal now stays dismissed until two position
  reports in a row are past the target.

## 0.5.1

- Royalty usage (EYF-231): with `offerId`, `drmAuthorization` and a
  storefront, a film reports the seconds the viewer watched to
  `playback-events` for licensor royalties: every 30 s while playing, on a
  pause, at the end, when the app goes to the background and when the player
  closes. Ads, pauses, seeks and stalls don't count, and it works with or
  without a player key. `PlaybackCoordinatorConfig` takes `offerId` and
  `catalogueId`; `UsageReporter`, `HttpUsageSender` and `usageSender` are
  public.

## 0.5.0

- Renamed (EYF-225): every public `Eyzflow…` name is now spelled `EYZFlow…`
  to match the product, e.g. `EYZFlowPlayer`, `EYZFlowSource`, `EYZFlowFilm`,
  `EYZFlowEndpoints`, `EYZFlowPlayerStatus` and `setEYZFlowPlayerLanguage`.
  The old names still work as deprecated aliases and are removed in 0.6.0.
  The package name `eyzflow_player` is unchanged. The native plugin classes
  are now `EYZFlowPlayerPlugin`; Flutter regenerates the registrant on the
  next build.

## 0.4.0

- Skip intro, recap and credits (EYF-214). The signals marked on a stream
  (Stream → Signals) are read from its HLS playlist, on every route. While
  playback is in one, a "Skip intro", "Skip recap" or "Skip credits" button
  shows: tapped on phones and tablets; on TV it holds focus while the
  controls are hidden, so OK skips. `features.skipButtons: false` hides it.
  The button takes the config's theme. Text in en, de, fr and nl.
- New playback events `PlaybackSignalStarted` and `PlaybackSignalEnded`, and
  `EYZFlowPlayer.onSignal`, for offering the next episode at the closing
  credits. `PlaybackEvent` is sealed: an exhaustive `switch` over it needs
  the two new cases.
- The stream's playlist is now read once per playback for its markers even
  without ads; `loadHlsAdBreaks` is replaced by `loadHlsMarkers`.
- `skipButtonTypes` (EYF-223): the skip button per signal type, from the
  player config or inline. By default intro, recap and opening credits; no
  "Skip credits" over the closing credits unless `closingCredits: true`.
- An end screen (EYF-222): `EYZFlowPlayer.endScreen` shows "Up next" with a
  countdown and a row of films the app passes, at the closing credits (the
  video shrunk into a corner) or after the film; a picked film plays in
  place with its own key check, session and DRM (`onSelect` can prevent it).
  On TV it takes the remote's focus. A stream without a closing credits
  signal gets it `secondsBeforeEnd` seconds before the end (default 20). The
  config's `features.endScreen` and `endScreen` settings apply.
  `overlayBuilder` draws the app's own UI instead. When it appears in native
  full screen the player leaves full screen, and at the end of the film it
  stays open on the end screen. Texts in en, de, fr and nl.

## 0.3.0

- Ads follow the viewer's plan (EYF-210). The playback session's `ads` and
  `ad_targeting` (`PlaybackSession.ads`, `PlaybackSession.adTargeting`) are
  read before the player loads: `ads: false` makes no ad request at all, and
  `ad_targeting` is added to the tag's `cust_params` (a key the tag already
  sets keeps the tag's value). Without an answer the config decides, as
  before. `EyzflowPlayerReady` has the new `planAds` and `adTargeting` fields,
  and `PlayerOptions.withAds()` swaps the ads once the plan has answered.
- Playback sessions now open for clear streams too, whenever
  `drmAuthorization` and a storefront are given, so a plan's stream limit
  counts trailers. A host that passes them for trailers can now get
  `onLimitReached` there.
- A countdown before each mid-roll (EYF-208): a corner notice, "Ad in 5" …
  "Ad in 1", for the stream's ad break markers, else a VMAP tag's mid-roll
  cue points (never a pre-roll or post-roll). In en, de, fr and nl. It hides
  while paused or seeking, during an ad, on AirPlay and once the break is
  seeked past. It takes no touch or focus; on Android TV it stays up while the
  controls are hidden.
  - `features.adCountdown` (`PlayerFeatures.adCountdown`) switches it; missing
    means on.
  - `ads.countdownSeconds` (`PlayerAdsConfig.countdownSeconds`) sets its
    length, 1–30 s, default 5 (`adCountdownLength()` rounds and clamps).
  - Both apply from an inline `config` change without reloading the stream
    (`PlayerOptions.adCountdown`, `adCountdownSeconds`, `withAdCountdown()`).
- `PlayerFeatures.toJson()` and `PlayerAdsConfig.toJson()` now include
  `adCountdown` and `countdownSeconds`.

## 0.2.0

- Ads from the player config (`features.ads`, `ads.adTagUrl`) on Android,
  Android TV and iOS, through Google IMA (`interactive_media_ads`). Ad breaks
  follow the stream's SCTE-35 markers; streams without markers follow the tag.
  See the README's Ads section.
- `PlaybackAdBreakStarted` and `PlaybackAdBreakEnded` playback events; a
  host's exhaustive `switch` over `PlaybackEvent` needs the two new cases.
- `BeatCollector.beginAd` / `endAd`: ad time is left out of the beats.
- Android apps need core library desugaring for IMA (README, Host setup).

## 0.1.0

First release.

- `EyzflowPlayer`: full-screen playback of EYZFlow streams on Android, Android
  TV, iOS and Samsung Tizen TVs, with Widevine and FairPlay DRM, subtitles,
  audio tracks, resume and watch progress (`WatchProgressStore`).
- The EYZFlow rules around playback: the player key check, playback sessions
  for stream and device limits, and playback quality analytics.
- Player configs from the dashboard (`configId`) with inline overrides.
- Chromecast on phones and tablets through the EYZFlow Cast receiver, and
  AirPlay on iOS.
- TV controls for remotes: fast seeking with thumbnail previews, audio and
  subtitle panels with built-in language names (en, de, fr, nl).
- Headless clients for the key check, playback sessions and analytics.
