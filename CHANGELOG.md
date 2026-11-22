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
