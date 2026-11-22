# eyzflow_player example

A loader app for `eyzflow_player`. The form takes a stream ID, title, film or
trailer, the viewer's bearer token, the storefront, an optional player key and
API origin; Play opens `EYZFlowPlayer` full screen. The log under the form
shows every playback event, every beat sent, and every limit or key refusal.

A film needs the viewer's bearer token (a Cognito access token), which the
player wraps into the DRM `access-token` with the storefront, device id,
playback session and player token. A trailer needs only its stream ID.

## Run

```sh
flutter pub get
flutter run                     # Android phone/tablet, Android TV, iOS
flutter-tizen run -d <device>   # Samsung TV
```

To prefill the form, pass `--dart-define=EYZFLOW_STREAM_ID=<stream id>` and
`--dart-define=EYZFLOW_STOREFRONT_ID=<storefront id>`;
`EYZFLOW_AD_TAG_URL=<VAST or VMAP tag>` turns ads on with that tag,
`EYZFLOW_TRAILER=true` plays the stream as a trailer, `EYZFLOW_TV=true`
starts in the TV layout and `EYZFLOW_AUTOPLAY=true` plays at launch (typing
on a TV remote is slow).

For an iPhone or iPad, put your Apple team in `ios/Flutter/Team.xcconfig`
(git-ignored): `DEVELOPMENT_TEAM = <team id>`.

The platform folders carry what a host needs: `MainActivity` forwarding to
`AndroidPlaybackHost`, `minSdk` 25 and the leanback entry on Android, the
`internet` and `drmplay` privileges on Tizen, iOS 15. See the package README's
"Host setup".

The app id is `com.eyzmedia.eyzflow_player_example`: add it to a player key's
allowed apps (as `android` and `androidtv`) to try the key check.
