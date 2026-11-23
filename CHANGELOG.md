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
