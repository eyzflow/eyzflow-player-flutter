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

## Subtitles and audio on the TV

On a TV with a remote (Google TV, TVs with Chromecast built-in), **Up** or
**Menu** opens a menu over the film with **Subtitles** (Off and each subtitle
track) and **Audio** (each audio track, when there is more than one). Up and
Down move, OK picks, Back closes, and it closes by itself after 8 seconds.
Tracks show their name, else their language; forced subtitles are marked
"(forced)" when the Cast framework lists them.

The menu switches tracks through the framework's track managers, so the
sender's media status (`activeTrackIds`) follows and the phone's or browser's
menus show the TV's choice. While the menu is closed, OK, Left and Right stay
with the player (play/pause, seek). A Chromecast without a remote sends no
keys, so the menu never shows there.

## Set up

EYZFlow hosts this receiver at `https://stream.eyzflow.com/cast/index.html`,
registered with Google as the published Custom Receiver **"EYZFlow Player",
application id `A534F914`**. Apps use it as it is:

```dart
EYZFlowPlayer(castReceiverAppId: 'A534F914', …)
```

To run your own copy, host `index.html` over HTTPS (no build step), register
it as a Custom Receiver in the [Google Cast SDK developer
console](https://cast.google.com/publish) and pass its application id instead.
Until it is published, only devices registered there by serial number can load
it; others answer `LAUNCH_ERROR: NOT_FOUND`.

## Debug

Open `chrome://inspect` on a computer on the same network as a registered test
device while it casts; the receiver logs refused licences with the backend's
code (`STREAM_LIMIT`, `DEVICE_LIMIT`, `PLAYER_KEY_INVALID`, …). With verbose
logging on, it also logs every remote key (`[eyzflow-receiver] key`), whether
the device reports D-pad input, and the text and audio tracks the framework
lists for each film (with their DASH roles, e.g. `forced_subtitle`).
