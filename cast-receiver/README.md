# EYZFlow Cast receiver

The page a Chromecast or Google TV loads when an EYZFlow player casts to it
(`index.html`, no build step). It plays the stream the phone names and adds the
DRM `access-token` header to every Widevine licence request. Google's standard
receiver (`CC1AD845`) cannot add that header, so with it only clear trailers
would play.

## What the sender sends

A `LOAD` with `media.contentId` set to the stream id and:

```json
{
  "manifestUrl": "https://stream.eyzflow.com/<stream id>/manifest.mpd",
  "licenseUrl": "https://api.eyzflow.com/v1/drm/<stream id>/widevine/acquire",
  "accessToken": "<base64 access-token, as the phone sends it>"
}
```

as `media.customData`. A clear stream (a trailer) leaves out `licenseUrl` and
`accessToken`. The receiver plays the DASH manifest with Widevine, the same
path as the web player; the phones play HLS. Both manifests address the same
encrypted segments.

The access token carries the phone's `device_id` and `playback_session_id`, so
the film on the TV counts as the phone's one stream. The phone keeps the
session heartbeating while it casts.

## Set up

EYZFlow hosts this receiver at `https://stream.eyzflow.com/cast/index.html`,
registered with Google as the published Custom Receiver **"EYZFlow Player",
application id `A534F914`**. Apps use it as it is:

```dart
EyzflowPlayer(castReceiverAppId: 'A534F914', …)
```

To run your own copy, host `index.html` over HTTPS (no build step), register
it as a Custom Receiver in the [Google Cast SDK developer
console](https://cast.google.com/publish) and pass its application id instead.
Until it is published, only devices registered there by serial number can load
it; others answer `LAUNCH_ERROR: NOT_FOUND`.

## Debug

Open `chrome://inspect` on a computer on the same network as a registered test
device while it casts; the receiver logs refused licences with the backend's
code (`STREAM_LIMIT`, `DEVICE_LIMIT`, `PLAYER_KEY_INVALID`, …).
