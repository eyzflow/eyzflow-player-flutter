## Unreleased

- MIT licence.
- The native player for Android and iOS is part of this package (it was the
  patched `better_native_video_player` under `third_party/`), so
  `eyzflow_player` is now a plugin with no path dependencies. Breaking for
  Android hosts: `AndroidPlaybackHost` moved to
  `com.eyzflow.player.playback`. Platform channels, the Android package and
  the iOS pod are renamed, so the upstream plugin can be used alongside.
- No dependency on `eyzflow_core` any more. Breaking:
  - `EYZFlowVideoStreamSource` → `EyzflowSource`; `EYZFlowFeatureLengthSource`
    / `EYZFlowTrailerSource` → `EyzflowFilm` / `EyzflowTrailer` (field
    `catalogueId`); URL getters `fairplayLicenseUrl`, `widevineLicenseUrl`,
    `thumbnailsUrl`, all non-null.
  - `EyzflowPlayer(watchHistory:)` → `watchProgressStore:` taking a
    `WatchProgressStore` the app implements.
  - The player's language: `EyzflowPlayer(language:)` or
    `setEyzflowPlayerLanguage`, else the device's (was the storefront's via
    `initializeEYZFlowStorefront`).
  - Track language names are built in (`EyzflowLanguageNames`, generated from
    Unicode CLDR for en, de, fr, nl), so the TV panels show names without the
    app loading tables.

- Player configs: `configId` loads the dashboard's player config
  (`GET /v1/player-configs/{id}`, kept in memory per id, defaults when it
  cannot be loaded), and an inline `config` (`PlayerConfigOverride`) merges
  over it with the web player's rules. The theme styles the Android TV and
  Tizen controls overlay; `controls`, `autoHideControls` and `captions` apply
  there; `loop` on Android, Android TV and iOS; `chromecast`, `airplay` and
  `pip` on phones; `cast.receiverAppId` is the default Cast receiver;
  `drm.parameters` (with `storefront_id`) go into the DRM access token. What
  is not honoured is listed in the README.
- Native player patch: `allowsExternalPlayback` (iOS), so AirPlay can be
  turned off.

- Chromecast on Android and iOS phones and tablets: a Cast button once a TV is
  found, device picker, casting screen, hand-over at the current position and
  back, with the playback session, beats and watch progress kept going.
- `cast-receiver/`: the EYZFlow Cast receiver, which adds the DRM access token
  to Widevine licence requests.
- Native player patches: Cast receiver app id, `customData` and load errors in
  `CastSession`; a Wi-Fi multicast lock for discovery on Android; a Cast
  button in the Android fullscreen controls; FairPlay rewritten to Apple's
  AVContentKeySession flow (SPC from the certificate, raw CKC), which iPhone
  playback and AirPlay need.
- Faster seeking on TV: ±15 s presses and remote scrubbing on the progress
  bar move the shown position at once and seek once after the last press
  (speeding up while held); Android seeks land on the nearest keyframe.
- Thumbnail previews on the TV seek bar: the frame of the previewed time,
  from the stream's WebVTT thumbnail track, shows above the thumb while
  skipping, scrubbing with the remote or dragging.

## 0.1.0

- The player moved in from the EYZFlow VOD apps,
  with `onPlaybackEvent`, and the patched `better_native_video_player` under
  `third_party/`.
- `EyzflowPlayer`: the player with the player key check, playback sessions for
  stream and device limits, and playback quality beats.
- Headless clients for the key check, playback sessions and beats.
