# The native player (Android and iOS)

`lib/src/native`, `android/` and `ios/` are the package's native player. They
started as a copy of
[better_native_video_player](https://pub.dev/packages/better_native_video_player)
1.5.2 (MIT, see `THIRD_PARTY_LICENSE_better_native_video_player`) and now
differ from it in many places, so the package no longer depends on it. The
upstream example app, tests and planning docs are not included.

Identifiers are EYZFlow's own, so an app can also use the upstream plugin:

| | Upstream | Here |
|---|---|---|
| Android package | `com.huddlecommunity.better_native_video_player` | `com.eyzflow.player` |
| Plugin class | `NativeVideoPlayerPlugin` | `EyzflowPlayerPlugin` |
| iOS pod / Swift package | `better_native_video_player` | `eyzflow_player` |
| Platform channels and view type | `native_video_player…` | `eyzflow_player_native…` |
| Android resources | `bnvp_…` | `eyzflow_player_…` |

## Changes from upstream

- Android: playback ownership (below): one command guard, hidden playback
  paused, no media foreground service.
- Android: the subtitle button on the native `PlayerView` (Media3 hides it by
  default) and an app-owned fullscreen route with Close (below).
- iOS: FairPlay licence requests carry the EYZFlow `access-token` header;
  AirPlay changes.
- Chromecast: launches the EYZFlow receiver with the access token instead of
  Google's Default Media Receiver.

When pulling a fix from upstream, port it by hand; do not replace these files.

## Android playback ownership

Each controller owns one ExoPlayer and a shared command guard. Native controls,
Flutter commands and MediaSession all use the guard. Hidden playback is paused;
restoring visibility does not restart it. Asynchronous startup requests are
invalidated by a newer pause, exit or loss of visibility.

The MediaSession exists while the player is eligible for visible playback and
is independent of artwork availability. ExoPlayer owns audio focus and handles
headphone disconnection. The package no longer declares or starts a media
playback foreground service, or holds network wake locks for background audio.
Host lifecycle and PiP integration must drive visibility; creating a controller
alone does not grant permission to play hidden media.

## Android app-owned fullscreen routes

Set `androidFullscreenRoute: true` when the platform view already fills the
app's player route, and supply `androidCloseLabel` in the app's language.
With native controls enabled, Close lives in Media3's animated controller and
hides with the transport controls and in PiP. Android 15+ hosts should forward
`onPictureInPictureUiStateChanged` with `isTransitioningToPip` to
`AndroidPlaybackHost.onPictureInPictureTransitionStarted` to hide controls before
the entry animation. Mode-change events still drive playback visibility. The redundant expand buttons are
hidden; this option does not open a native Dialog or change orientation.

Leaving PiP restores the configured embedded-caption size, including Android's
system caption font-size preference, on both native display paths.

Listen to `androidPlaybackEvents`: `closed == true` with reason `closeButton`
requests route dismissal and supplies the current position. Native playback is
stopped immediately and late startup Play is invalidated. The app must save
progress and dispose the controller; Close is not natural completion.

The option defaults to false, retaining inline/fullscreen behavior for other
consumers. Shared TV overlays keep their own Close. The route controller layout
is based on Apache-licensed Media3 1.5.0 `exo_player_control_view.xml`, with Close
inside its animated background container; review it when updating Media3.
