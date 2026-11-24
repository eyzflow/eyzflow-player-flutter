import 'dart:async';
import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _tv = CastTarget(id: 'tv-1', name: 'Living Room TV', model: 'Chromecast');

/// A TV on the network that records what it was asked and reports what the
/// test tells it to.
final class _FakeTv implements CastConnection {
  final _playback = StreamController<CastPlayback>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final calls = <String>[];
  CastMedia? loaded;
  CastPlayback _current = const CastPlayback();

  void report(CastPlayback playback) {
    _current = playback;
    _playback.add(playback);
  }

  void refuse(String reason) => _errors.add(reason);

  void disconnect() => _playback.close();

  @override
  Stream<CastPlayback> get playback => _playback.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  CastPlayback get current => _current;

  @override
  Future<void> load(CastMedia media) async {
    loaded = media;
    calls.add('load');
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async => calls.add('seek $position');

  @override
  Future<void> stop() async => calls.add('stop');
}

final class _FakeBackend implements CastBackend {
  List<CastTarget> devices = const [_tv];
  final tv = _FakeTv();
  String? appId;
  var scans = 0;
  var connects = 0;
  Object? connectError;

  /// Fails only the first connection, like a TV that restarted on a new port.
  Object? firstConnectError;

  @override
  Future<List<CastTarget>> discover({Duration? timeout}) async {
    scans += 1;
    return devices;
  }

  @override
  Future<CastConnection> connect(
    CastTarget target, {
    required String appId,
  }) async {
    this.appId = appId;
    connects += 1;
    final first = firstConnectError;
    if (first != null && connects == 1) throw first;
    if (connectError != null) throw connectError!;
    return tv;
  }
}

const _media = CastMedia(
  streamId: 's',
  contentUrl: 'https://stream.eyzflow.com/s/manifest.mpd',
  contentType: 'application/dash+xml',
  title: 'Film',
  startAt: Duration(minutes: 10),
);

Duration _min(int m) => Duration(minutes: m);

void main() {
  group('EYZFlowCastController', () {
    late _FakeBackend backend;
    late List<(CastEndReason, Duration)> ended;
    late List<CastPlayback> playbacks;
    late EYZFlowCastController cast;

    setUp(() {
      backend = _FakeBackend();
      ended = [];
      playbacks = [];
      cast = EYZFlowCastController(
        backend: backend,
        onPlayback: playbacks.add,
        onEnded: (reason, position) => ended.add((reason, position)),
      );
    });

    test('scans for TVs', () async {
      expect(cast.devices, isEmpty);
      await cast.scan();
      expect(cast.devices, [_tv]);
      expect(cast.scanning, isFalse);
    });

    test('a failed scan leaves no devices', () async {
      final failing = EYZFlowCastController(backend: _ThrowingBackend());
      await failing.scan();
      expect(failing.devices, isEmpty);
    });

    test('connects to the receiver, loads and reports the TV', () async {
      await cast.cast(_tv, _media, appId: 'ABCD1234');

      expect(backend.appId, 'ABCD1234');
      expect(backend.tv.loaded, same(_media));
      expect(cast.state, isA<CastConnecting>());

      backend.tv.report(
        CastPlayback(state: CastPlayerState.playing, position: _min(10)),
      );
      expect(cast.state, isA<CastActive>());
      expect(playbacks.single.position, _min(10));
    });

    test('stop ends at the TV position and stops the receiver', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(state: CastPlayerState.playing, position: _min(12)),
      );

      await cast.stop();

      expect(ended, [(CastEndReason.stopped, _min(12))]);
      expect(backend.tv.calls.last, 'stop');
      expect(cast.state, isA<CastOff>());
    });

    test('stop while connecting resumes where the phone was', () async {
      await cast.cast(_tv, _media, appId: 'A');
      await cast.stop();
      expect(ended, [(CastEndReason.stopped, _min(10))]);
    });

    test('the film ending on the TV is reported once', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.playing,
          position: _min(10),
          duration: _min(90),
        ),
      );
      backend.tv.report(
        CastPlayback(idleReason: 'FINISHED', duration: _min(90)),
      );
      backend.tv.disconnect();

      expect(ended, [(CastEndReason.finished, _min(90))]);
    });

    test('the TV closing the connection ends at its last position', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(state: CastPlayerState.paused, position: _min(20)),
      );
      backend.tv.disconnect();
      await Future<void>.delayed(Duration.zero);

      expect(ended, [(CastEndReason.disconnected, _min(20))]);
      expect(backend.tv.calls, isNot(contains('stop')));
    });

    test('a refused load fails, at the start position', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.refuse('LOAD_FAILED / 104');

      expect(ended, [(CastEndReason.failed, _min(10))]);
      expect(cast.state, isA<CastFailed>());
    });

    test('a connection that cannot be made fails', () async {
      backend.connectError = Exception('refused');
      await cast.cast(_tv, _media, appId: 'A');
      expect(ended.single.$1, CastEndReason.failed);
      expect(cast.isCasting, isFalse);
    });

    test('a refused address is looked up again and retried once', () async {
      backend.firstConnectError = Exception('Connection refused');
      await cast.cast(_tv, _media, appId: 'A');

      expect(backend.connects, 2);
      expect(backend.scans, 1);
      expect(cast.state, isA<CastConnecting>());
      expect(backend.tv.loaded, same(_media));
    });

    test('a refused receiver is not retried', () async {
      backend.connectError = StateError('Cast LAUNCH_ERROR: NOT_FOUND');
      await cast.cast(_tv, _media, appId: 'A');

      expect(backend.connects, 1);
      expect(ended.single.$1, CastEndReason.failed);
    });

    test('a TV that never starts playing fails after the load timeout', () {
      fakeAsync((async) {
        final slow = EYZFlowCastController(
          backend: backend,
          onEnded: (reason, position) => ended.add((reason, position)),
          loadTimeout: const Duration(seconds: 20),
        );
        slow.cast(_tv, _media, appId: 'A');
        async.flushMicrotasks();
        backend.tv.report(const CastPlayback(state: CastPlayerState.buffering));
        async.elapse(const Duration(seconds: 19));
        expect(ended, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(ended.single.$1, CastEndReason.failed);
      });
    });

    test('transport goes to the TV', () async {
      await cast.cast(_tv, _media, appId: 'A');
      await cast.pause();
      await cast.play();
      await cast.seek(_min(30));
      expect(backend.tv.calls, ['load', 'pause', 'play', 'seek ${_min(30)}']);
    });
  });

  group('castMediaFor', () {
    const source = EYZFlowSource(
      id: 'stream-1',
      title: 'Film',
      sourceType: EYZFlowFilm('cat'),
    );

    test('a film carries the licence URL and the access token', () {
      final media = castMediaFor(
        source,
        startAt: _min(5),
        accessHeader: 'token',
      );
      expect(
        media.contentUrl,
        'https://stream.eyzflow.com/stream-1/manifest.mpd',
      );
      expect(media.contentType, 'application/dash+xml');
      expect(media.startAt, _min(5));
      expect(media.customData, {
        'manifestUrl': 'https://stream.eyzflow.com/stream-1/manifest.mpd',
        'licenseUrl':
            'https://api.eyzflow.com/v1/drm/stream-1/widevine/acquire',
        'accessToken': 'token',
      });
    });

    test('a clear stream carries no licence', () {
      final media = castMediaFor(source, startAt: Duration.zero);
      expect(media.customData, {
        'manifestUrl': 'https://stream.eyzflow.com/stream-1/manifest.mpd',
      });
    });
  });

  group('EYZFlowPlayer casting', () {
    setUpAll(() => setEYZFlowPlayerLanguage('en'));

    Future<_FakeBackend> pump(
      WidgetTester tester, {
      String? receiver = 'ABCD1234',
      bool isTv = false,
      List<PlaybackEvent>? events,
    }) async {
      final backend = _FakeBackend();
      final client = MockClient((request) async {
        if (request.method == 'DELETE') return http.Response('', 204);
        if (request.url.path.endsWith('/heartbeat')) {
          return http.Response(jsonEncode({'status': 'active'}), 200);
        }
        return http.Response(jsonEncode({'id': 'ps_1'}), 201);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EYZFlowPlayer(
            streamId: 'stream-1',
            title: 'Film',
            sourceType: const EYZFlowFilm('cat'),
            drmAuthorization: 'Bearer viewer',
            storefrontId: 'sf',
            isTv: isTv,
            httpClient: client,
            deviceIdStore: MemoryDeviceIdStore('device-1'),
            castReceiverAppId: receiver,
            castBackend: backend,
            debugOperatingSystemOverride: 'android',
            onPlaybackEvent: events?.add,
            playerBuilder: (_, _) => const SizedBox(key: Key('player')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      return backend;
    }

    VideoplayerFeatureView view(WidgetTester tester) => tester
        .widget<VideoplayerFeatureView>(find.byType(VideoplayerFeatureView));

    testWidgets('offers Cast once a TV is found', (tester) async {
      final backend = await pump(tester);
      expect(backend.scans, 1);
      expect(view(tester).castAvailable, isTrue);
    });

    testWidgets('a film without a receiver id casts to the EYZFlow receiver', (
      tester,
    ) async {
      final backend = await pump(tester, receiver: null);
      expect(view(tester).castAvailable, isTrue);

      view(tester).onCastRequested!(_min(10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();
      expect(backend.appId, 'A534F914');
      expect(backend.tv.loaded!.customData!['accessToken'], isA<String>());
    });

    testWidgets('a TV app offers no Cast', (tester) async {
      final backend = await pump(tester, isTv: true);
      expect(backend.scans, 0);
    });

    testWidgets('casting hands the film to the TV and back', (tester) async {
      final events = <PlaybackEvent>[];
      final backend = await pump(tester, events: events);

      view(tester).onCastRequested!(_min(10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();

      // The TV loads the film from the phone's position, with its DRM.
      final loaded = backend.tv.loaded!;
      expect(backend.appId, 'ABCD1234');
      expect(loaded.startAt, _min(10));
      final token = loaded.customData!['accessToken']! as String;
      final payload = jsonDecode(utf8.decode(base64Decode(token))) as Map;
      expect((payload['parameters'] as Map)['playback_session_id'], 'ps_1');
      expect(find.byKey(const Key('player')), findsNothing);
      expect(find.text('Connecting to Living Room TV…'), findsOneWidget);

      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.playing,
          position: _min(10),
          duration: _min(90),
        ),
      );
      await tester.pump();
      expect(find.text('Playing on Living Room TV'), findsOneWidget);
      expect(events.whereType<PlaybackResumed>(), isNotEmpty);

      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.playing,
          position: _min(25),
          duration: _min(90),
        ),
      );
      await tester.tap(find.text('Stop casting'));
      await tester.pumpAndSettle();

      // The phone plays again, from where the TV was.
      expect(find.byKey(const Key('player')), findsOneWidget);
      expect(_progress(view(tester)), 25 * 60);
      expect(backend.tv.calls.last, 'stop');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused cast shows why and the phone plays on', (
      tester,
    ) async {
      final backend = await pump(tester);
      view(tester).onCastRequested!(_min(3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();

      backend.tv.refuse('LOAD_FAILED');
      await tester.pumpAndSettle();

      expect(find.text('Could not play on Living Room TV.'), findsOneWidget);
      expect(find.byKey(const Key('player')), findsOneWidget);
      expect(_progress(view(tester)), 3 * 60);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

double? _progress(VideoplayerFeatureView view) => switch (view.target) {
  VideoplayerSourceTarget(:final source) => source.progressSeconds,
  VideoplayerTrailerTarget(:final source) => source.progressSeconds,
};

final class _ThrowingBackend implements CastBackend {
  @override
  Future<List<CastTarget>> discover({Duration? timeout}) =>
      Future.error(Exception('no wifi'));

  @override
  Future<CastConnection> connect(CastTarget target, {required String appId}) =>
      Future.error(UnimplementedError());
}
