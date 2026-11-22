import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A fake api.eyzflow.com: answers by path and records every request.
final class _Backend {
  final requests = <http.Request>[];
  http.Response Function(http.Request) license = (_) => _json({
    'token': 'plk1.a.b',
    'mode': 'enforce',
    'analytics': {'enabled': true, 'heartbeat_interval_seconds': 60},
  });
  http.Response Function(http.Request) open = (_) =>
      _json({'id': 'ps_1', 'heartbeat_interval_seconds': 30}, 201);
  http.Response Function(http.Request) heartbeat = (_) =>
      _json({'status': 'active'});

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/v1/player/license') return license(request);
    if (path.endsWith('/heartbeat')) return heartbeat(request);
    if (request.method == 'DELETE') return http.Response('', 204);
    if (path.endsWith('/playback-sessions')) return open(request);
    return http.Response('not found', 404);
  });

  List<String> get calls => [
    for (final r in requests) '${r.method} ${r.url.path}',
  ];
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Map<String, Object?> _decodeHeader(String header) =>
    jsonDecode(utf8.decode(base64Decode(header))) as Map<String, Object?>;

PlaybackCoordinator _coordinator(
  _Backend backend, {
  PlaybackCoordinatorConfig config = const PlaybackCoordinatorConfig(
    streamId: 'stream-1',
    isProtected: true,
    playerKey: 'pk_x',
    drmAuthorization: 'Bearer viewer',
    storefrontId: 'sf',
    drmParameters: {'source': 'internal'},
    platform: PlayerPlatform.android,
    app: PlayerApp(platform: PlayerPlatform.android, id: 'com.example.app'),
  ),
  List<Beat>? beats,
  List<PlaybackLimitError>? limits,
  List<PlayerLicenseError>? refusals,
  List<String>? errors,
}) => PlaybackCoordinator(
  config: config,
  licenseClient: PlayerLicenseClient(client: backend.client),
  sessionClient: PlaybackSessionClient(client: backend.client),
  beatSender: (beat) async {
    beats?.add(beat);
    return true;
  },
  deviceIdStore: MemoryDeviceIdStore('device-1'),
  onLimitReached: limits?.add,
  onLicenseError: refusals?.add,
  onError: errors?.add,
  now: () => 0,
);

void main() {
  test('checks the key, opens a session and builds the access token', () {
    fakeAsync((async) {
      final backend = _Backend();
      final coordinator = _coordinator(backend)..start();
      async.flushMicrotasks();

      expect(backend.calls, [
        'POST /v1/player/license',
        'POST /v1/content/storefront/sf/playback-sessions',
      ]);
      expect(
        jsonDecode(backend.requests.first.body),
        containsPair('app', {'platform': 'android', 'id': 'com.example.app'}),
      );
      expect(backend.requests[1].headers['X-Device-Id'], 'device-1');
      final status = coordinator.status as EyzflowPlayerReady;
      expect(_decodeHeader(status.drmAccessHeader!), {
        'headers': {'authorization': 'Bearer viewer'},
        'parameters': {
          'source': 'internal',
          'storefront_id': 'sf',
          'device_id': 'device-1',
          'playback_session_id': 'ps_1',
          'player_token': 'plk1.a.b',
        },
      });
      coordinator.dispose();
      async.flushMicrotasks();
    });
  });

  test('heartbeats the session, and closes it with a final beat', () {
    fakeAsync((async) {
      final backend = _Backend();
      final beats = <Beat>[];
      final coordinator = _coordinator(backend, beats: beats)..start();
      async.flushMicrotasks();
      coordinator.onPlaybackEvent(
        const PlaybackStarted(sourceId: 'stream-1', position: Duration.zero),
      );
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 61));
      coordinator.dispose();
      async.flushMicrotasks();

      expect(
        backend.calls.where((c) => c.endsWith('/heartbeat')),
        hasLength(2),
      );
      expect(
        backend.calls.last,
        'DELETE /v1/content/storefront/sf/playback-sessions/ps_1',
      );
      expect(beats.map((b) => b.isFinal), [false, false, true]);
      expect(beats.every((b) => b.platform == 'android'), isTrue);
      expect(beats.first.drm, 'widevine');
    });
  });

  test('a stream limit fails before playback and reaches the host', () {
    fakeAsync((async) {
      final backend = _Backend()
        ..open = (_) => _json({'code': 'STREAM_LIMIT', 'sessions': []}, 403);
      final limits = <PlaybackLimitError>[];
      final errors = <String>[];
      final coordinator = _coordinator(backend, limits: limits, errors: errors)
        ..start();
      async.flushMicrotasks();

      final status = coordinator.status as EyzflowPlayerFailed;
      expect(status.failure, isA<EyzflowLimitFailure>());
      expect(limits.single.code, PlaybackLimitCode.streamLimit);
      expect(errors.single, contains('too many screens'));
      coordinator.dispose();
    });
  });

  test('a refused key fails before any session', () {
    fakeAsync((async) {
      final backend = _Backend()
        ..license = (_) => _json({'code': 'PLAYER_KEY_INVALID'}, 403);
      final refusals = <PlayerLicenseError>[];
      final coordinator = _coordinator(backend, refusals: refusals)..start();
      async.flushMicrotasks();

      expect(coordinator.status, isA<EyzflowPlayerFailed>());
      expect(refusals.single.code, PlayerLicenseCode.playerKeyInvalid);
      expect(backend.calls, ['POST /v1/player/license']);
      coordinator.dispose();
    });
  });

  test('an unreachable key check plays on without token or beats', () {
    fakeAsync((async) {
      final backend = _Backend()..license = (_) => http.Response('', 502);
      final beats = <Beat>[];
      final coordinator = _coordinator(backend, beats: beats)..start();
      async.flushMicrotasks();

      final status = coordinator.status as EyzflowPlayerReady;
      expect(
        (_decodeHeader(status.drmAccessHeader!)['parameters']! as Map)
            .containsKey('player_token'),
        isFalse,
      );
      coordinator.onPlaybackEvent(
        const PlaybackStarted(sourceId: 'stream-1', position: Duration.zero),
      );
      coordinator.dispose();
      async.flushMicrotasks();
      expect(beats, isEmpty);
    });
  });

  test('a session ended elsewhere stops playback', () {
    fakeAsync((async) {
      final backend = _Backend()..heartbeat = (_) => _json({'status': 'ended'});
      final limits = <PlaybackLimitError>[];
      final coordinator = _coordinator(backend, limits: limits)..start();
      async.flushMicrotasks();
      expect(coordinator.status, isA<EyzflowPlayerReady>());

      async.elapse(const Duration(seconds: 30));

      expect(coordinator.status, isA<EyzflowPlayerFailed>());
      expect(limits.single.code, PlaybackLimitCode.playbackSessionEnded);
      expect(
        backend.calls.last,
        'DELETE /v1/content/storefront/sf/playback-sessions/ps_1',
      );
      coordinator.dispose();
    });
  });

  test('limits off: no heartbeat and no session id in the token', () {
    fakeAsync((async) {
      final backend = _Backend()..open = (_) => _json({'id': null});
      final coordinator = _coordinator(backend)..start();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 5));

      final status = coordinator.status as EyzflowPlayerReady;
      expect(
        (_decodeHeader(status.drmAccessHeader!)['parameters']! as Map)
            .containsKey('playback_session_id'),
        isFalse,
      );
      expect(backend.calls.where((c) => c.endsWith('/heartbeat')), isEmpty);
      coordinator.dispose();
    });
  });

  test('without a key or storefront: no calls, DRM header only', () {
    fakeAsync((async) {
      final backend = _Backend();
      final coordinator = _coordinator(
        backend,
        config: const PlaybackCoordinatorConfig(
          streamId: 'stream-1',
          isProtected: true,
          drmAuthorization: 'Bearer viewer',
        ),
      )..start();
      async.flushMicrotasks();

      expect(backend.calls, isEmpty);
      final status = coordinator.status as EyzflowPlayerReady;
      expect(_decodeHeader(status.drmAccessHeader!)['parameters'], {
        'device_id': 'device-1',
      });
      coordinator.dispose();
    });
  });

  test(
    "a storefront viewer's trailer opens a session but has no DRM header",
    () {
      fakeAsync((async) {
        final backend = _Backend()
          ..open = (_) => _json({
            'id': 'ps_1',
            'ads': false,
            'ad_targeting': {'plan': 'premium'},
          }, 201);
        final coordinator = _coordinator(
          backend,
          config: const PlaybackCoordinatorConfig(
            streamId: 'trailer-1',
            isProtected: false,
            drmAuthorization: 'Bearer viewer',
            storefrontId: 'sf',
          ),
        )..start();
        async.flushMicrotasks();

        expect(backend.calls, [
          'POST /v1/content/storefront/sf/playback-sessions',
        ]);
        expect(
          jsonDecode(backend.requests.single.body),
          containsPair('stream_id', 'trailer-1'),
        );
        final status = coordinator.status as EyzflowPlayerReady;
        expect(status.drmAccessHeader, isNull);
        expect(status.planAds, isFalse);
        expect(status.adTargeting, {'plan': 'premium'});

        async.elapse(const Duration(seconds: 30));
        expect(
          backend.calls.where((c) => c.endsWith('/heartbeat')),
          hasLength(1),
        );
        coordinator.dispose();
        async.flushMicrotasks();
        expect(
          backend.calls.last,
          'DELETE /v1/content/storefront/sf/playback-sessions/ps_1',
        );
      });
    },
  );

  test('a trailer without the viewer or a storefront opens no session', () {
    for (final config in const [
      PlaybackCoordinatorConfig(
        streamId: 'trailer-1',
        isProtected: false,
        storefrontId: 'sf',
      ),
      PlaybackCoordinatorConfig(
        streamId: 'trailer-1',
        isProtected: false,
        drmAuthorization: 'Bearer viewer',
      ),
    ]) {
      fakeAsync((async) {
        final backend = _Backend();
        final coordinator = _coordinator(backend, config: config)..start();
        async.flushMicrotasks();

        expect(backend.calls, isEmpty);
        final status = coordinator.status as EyzflowPlayerReady;
        expect(status.drmAccessHeader, isNull);
        expect(status.planAds, isNull);
        expect(status.adTargeting, isEmpty);
        coordinator.dispose();
      });
    }
  });

  test("a film's session passes the plan's ads answer on", () {
    fakeAsync((async) {
      final backend = _Backend()
        ..open = (_) => _json({
          'id': 'ps_1',
          'ads': true,
          'ad_targeting': {'plan': 'basic-ads', 'access': 'svod'},
        }, 201);
      final coordinator = _coordinator(backend)..start();
      async.flushMicrotasks();

      final status = coordinator.status as EyzflowPlayerReady;
      expect(status.planAds, isTrue);
      expect(status.adTargeting, {'plan': 'basic-ads', 'access': 'svod'});
      expect(
        _decodeHeader(status.drmAccessHeader!)['parameters'],
        containsPair('playback_session_id', 'ps_1'),
      );
      coordinator.dispose();
      async.flushMicrotasks();
    });
  });

  test('a failed session leaves ads to the config', () {
    fakeAsync((async) {
      final backend = _Backend()..open = (_) => http.Response('', 500);
      final coordinator = _coordinator(backend)..start();
      async.flushMicrotasks();

      final status = coordinator.status as EyzflowPlayerReady;
      expect(status.planAds, isNull);
      expect(status.adTargeting, isEmpty);
      expect(status.drmAccessHeader, isNotNull);
      coordinator.dispose();
    });
  });

  test('a DRM licence refused for the limit fails with that limit', () {
    fakeAsync((async) {
      final limits = <PlaybackLimitError>[];
      final coordinator = _coordinator(_Backend(), limits: limits)..start();
      async.flushMicrotasks();

      coordinator.onPlaybackEvent(
        const PlaybackError(
          sourceId: 'stream-1',
          position: Duration.zero,
          message: 'License request failed: {"code":"DEVICE_LIMIT"}',
        ),
      );
      async.flushMicrotasks();

      expect(limits.single.code, PlaybackLimitCode.deviceLimit);
      expect(coordinator.status, isA<EyzflowPlayerFailed>());
      coordinator.dispose();
    });
  });

  test('a renewal refusal stops playback only when enforcing', () {
    for (final mode in ['enforce', 'log']) {
      fakeAsync((async) {
        var checks = 0;
        final backend = _Backend()
          ..license = (_) {
            checks += 1;
            if (checks == 1) {
              return _json({'token': 't', 'mode': mode, 'refresh_after': 600});
            }
            return _json({'code': 'PLAYER_KEY_INVALID'}, 403);
          };
        final coordinator = _coordinator(backend)..start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 600));

        expect(
          coordinator.status,
          mode == 'enforce'
              ? isA<EyzflowPlayerFailed>()
              : isA<EyzflowPlayerReady>(),
          reason: mode,
        );
        coordinator.dispose();
        async.flushMicrotasks();
      });
    }
  });
}
