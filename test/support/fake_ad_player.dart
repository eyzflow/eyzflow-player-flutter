import 'dart:async';

import 'package:eyzflow_player/src/ads/vast.dart';
import 'package:eyzflow_player/src/ads/vast_ad_driver.dart';
import 'package:flutter/widgets.dart';

/// Stands in for the AVPlay player an ad plays in. The test drives it.
final class FakeAdPlayer implements AdMediaPlayer {
  FakeAdPlayer(
    this.media, {
    this.failInitialize = false,
    this.hangInitialize = false,
    this.duration = const Duration(seconds: 10),
  });

  final VastMediaFile media;
  final bool failInitialize;
  final bool hangInitialize;
  final Duration duration;
  final List<VoidCallback> _listeners = <VoidCallback>[];
  AdMediaValue _value = const AdMediaValue();
  var initialized = false;
  var played = false;
  var disposed = false;

  @override
  AdMediaValue get value => _value;

  @override
  Future<void> initialize() async {
    if (failInitialize) throw StateError('no decoder');
    if (hangInitialize) await Completer<void>().future;
    initialized = true;
    _set(AdMediaValue(isInitialized: true, duration: duration));
  }

  @override
  Future<void> play() async {
    played = true;
    _set(
      AdMediaValue(
        isInitialized: true,
        isPlaying: true,
        position: _value.position,
        duration: duration,
      ),
    );
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async => disposed = true;

  /// Playback reached [position].
  void advance(Duration position) => _set(
    AdMediaValue(
      isInitialized: true,
      isPlaying: true,
      position: position,
      duration: duration,
    ),
  );

  void complete() => _set(
    AdMediaValue(
      isInitialized: true,
      isCompleted: true,
      position: duration,
      duration: duration,
    ),
  );

  void fail(String message) =>
      _set(AdMediaValue(isInitialized: true, errorMessage: message));

  void _set(AdMediaValue value) {
    _value = value;
    for (final VoidCallback l in List<VoidCallback>.of(_listeners)) {
      l();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  Widget buildView() =>
      SizedBox.expand(key: ValueKey<String>('ad-view ${media.url}'));
}

String vastAd({
  String id = 'a',
  int? sequence,
  String skip = '',
  String duration = '00:00:10',
}) =>
    '''
<Ad id="$id"${sequence == null ? '' : ' sequence="$sequence"'}><InLine>
  <Impression>https://track.example/imp/$id</Impression>
  <Error>https://track.example/err/$id?c=[ERRORCODE]</Error>
  <Creatives><Creative><Linear$skip>
    <Duration>$duration</Duration>
    <TrackingEvents>
      <Tracking event="start">https://track.example/start/$id</Tracking>
      <Tracking event="complete">https://track.example/complete/$id</Tracking>
      <Tracking event="skip">https://track.example/skip/$id</Tracking>
    </TrackingEvents>
    <MediaFiles><MediaFile delivery="progressive" type="video/mp4" height="1080">https://cdn.example/$id.mp4</MediaFile></MediaFiles>
  </Linear></Creative></Creatives>
</InLine></Ad>''';

String vastOf(String ads) => '<VAST version="3.0">$ads</VAST>';

String vmapOf(Map<String, String> breaks) =>
    '<vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap" version="1.0">'
    '${breaks.entries.map((MapEntry<String, String> b) => '<vmap:AdBreak timeOffset="${b.key}" breakType="linear">'
        '<vmap:AdSource><vmap:AdTagURI>${b.value}</vmap:AdTagURI></vmap:AdSource></vmap:AdBreak>').join()}'
    '</vmap:VMAP>';
