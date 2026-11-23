## Unreleased

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
