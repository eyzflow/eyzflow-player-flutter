import 'dart:convert';

import 'package:eyzflow_player/src/core/api.dart';
import 'package:eyzflow_player/src/core/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _target = PlaybackSessionTarget(
  storefrontId: 'sf 1',
  authorization: 'Bearer viewer',
  deviceId: 'device-1',
);

void main() {
  group('open', () {
    test('posts the stream and platform with the viewer and device', () async {
      late http.Request sent;
      final client = PlaybackSessionClient(
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({'id': 'ps_1', 'heartbeat_interval_seconds': 45}),
            201,
          );
        }),
      );

      final session = await client.open(
        _target,
        streamId: 'stream-1',
        platform: PlayerPlatform.tizen,
        deviceName: 'Living room TV',
      );

      expect(session.id, 'ps_1');
      expect(session.heartbeatInterval, const Duration(seconds: 45));
      expect(
        sent.url.toString(),
        'https://api.eyzflow.com/v1/content/storefront/sf%201/playback-sessions',
      );
      expect(sent.headers['Authorization'], 'Bearer viewer');
      expect(sent.headers['X-Device-Id'], 'device-1');
      expect(sent.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), {
        'stream_id': 'stream-1',
        'platform': 'tizen',
        'device_name': 'Living room TV',
      });
    });

    test('a null id means the storefront has limits off', () async {
      final client = PlaybackSessionClient(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'id': null}), 200),
        ),
      );

      final session = await client.open(
        _target,
        streamId: 's',
        platform: PlayerPlatform.android,
      );

      expect(session.id, isNull);
      expect(session.heartbeatInterval, const Duration(seconds: 30));
    });

    test('throws the limit with its body', () async {
      final body = {
        'code': 'STREAM_LIMIT',
        'message': 'server text',
        'sessions': [
          {'device_name': 'Phone'},
        ],
      };
      final client = PlaybackSessionClient(
        client: MockClient((_) async => http.Response(jsonEncode(body), 403)),
      );

      await expectLater(
        client.open(_target, streamId: 's', platform: PlayerPlatform.android),
        throwsA(
          isA<PlaybackLimitException>()
              .having(
                (e) => e.error.code,
                'code',
                PlaybackLimitCode.streamLimit,
              )
              .having(
                (e) => e.error.message,
                'message',
                "You're watching on too many screens. Stop playback on another device to watch here.",
              )
              .having(
                (e) => e.error.details['sessions'],
                'sessions',
                isNotEmpty,
              ),
        ),
      );
    });

    test('throws a plain error for any other failure', () async {
      final client = PlaybackSessionClient(
        client: MockClient((_) async => http.Response('oops', 500)),
      );

      await expectLater(
        client.open(_target, streamId: 's', platform: PlayerPlatform.android),
        throwsA(isNot(isA<PlaybackLimitException>())),
      );
    });
  });

  group('heartbeat', () {
    Future<bool> beat(http.Response response) => PlaybackSessionClient(
      client: MockClient((request) async {
        expect(
          request.url.path,
          '/v1/content/storefront/sf%201/playback-sessions/ps_1/heartbeat',
        );
        return response;
      }),
    ).heartbeat(_target, 'ps_1');

    test('alive on ok', () async {
      expect(
        await beat(http.Response(jsonEncode({'status': 'active'}), 200)),
        isTrue,
      );
    });

    test('dead when ended, unauthorized or gone', () async {
      expect(
        await beat(http.Response(jsonEncode({'status': 'ended'}), 200)),
        isFalse,
      );
      expect(await beat(http.Response('', 401)), isFalse);
      expect(await beat(http.Response('', 404)), isFalse);
    });

    test('alive on a passing failure', () async {
      expect(await beat(http.Response('', 503)), isTrue);
      final offline = PlaybackSessionClient(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(await offline.heartbeat(_target, 'ps_1'), isTrue);
    });
  });

  // The API answers 400 to an empty body sent as application/json, which
  // failed every heartbeat and close.
  test('heartbeat and close send no JSON Content-Type and no body', () async {
    final sent = <http.Request>[];
    final client = PlaybackSessionClient(
      client: MockClient((request) async {
        sent.add(request);
        return http.Response(jsonEncode({'status': 'active'}), 200);
      }),
    );

    await client.heartbeat(_target, 'ps_1');
    await client.close(_target, 'ps_1');

    expect(sent, hasLength(2));
    for (final request in sent) {
      expect(request.headers.containsKey('Content-Type'), isFalse);
      expect(request.body, isEmpty);
      expect(request.headers['Authorization'], 'Bearer viewer');
      expect(request.headers['X-Device-Id'], 'device-1');
    }
  });

  test('close deletes the session and never throws', () async {
    final methods = <String>[];
    await PlaybackSessionClient(
      client: MockClient((request) async {
        methods.add('${request.method} ${request.url.path}');
        return http.Response('', 204);
      }),
    ).close(_target, 'ps_1');
    await PlaybackSessionClient(
      client: MockClient((_) async => throw http.ClientException('offline')),
    ).close(_target, 'ps_1');

    expect(methods, [
      'DELETE /v1/content/storefront/sf%201/playback-sessions/ps_1',
    ]);
  });

  group('ads', () {
    Future<PlaybackSession> openWith(Map<String, Object?> body) =>
        PlaybackSessionClient(
          client: MockClient((_) async => http.Response(jsonEncode(body), 201)),
        ).open(_target, streamId: 's', platform: PlayerPlatform.android);

    test("reads the plan's ads answer and its targeting", () async {
      final session = await openWith({
        'id': 'ps_1',
        'ads': true,
        'ad_targeting': {'plan': 'basic-ads', 'access': 'svod'},
      });

      expect(session.ads, isTrue);
      expect(session.adTargeting, {'plan': 'basic-ads', 'access': 'svod'});
    });

    test('a plan without ads', () async {
      final session = await openWith({'id': 'ps_1', 'ads': false});

      expect(session.ads, isFalse);
      expect(session.adTargeting, isEmpty);
    });

    test('an older backend says nothing: null, no targeting', () async {
      final session = await openWith({'id': 'ps_1'});

      expect(session.ads, isNull);
      expect(session.adTargeting, isEmpty);
    });

    test('ads that is not a bool is null', () async {
      for (final value in ['true', 1, null, <Object?>[]]) {
        expect((await openWith({'id': 'ps_1', 'ads': value})).ads, isNull);
      }
    });

    test('targeting keeps string values only', () async {
      final session = await openWith({
        'id': 'ps_1',
        'ads': true,
        'ad_targeting': {
          'plan': 'basic-ads',
          'tier': 2,
          'flag': true,
          'nested': {'a': 'b'},
          'none': null,
          'empty': '',
        },
      });

      expect(session.adTargeting, {'plan': 'basic-ads'});
    });

    test('targeting that is not an object is empty', () async {
      for (final value in [
        'plan=x',
        3,
        <Object?>['a'],
      ]) {
        final session = await openWith({'ads': true, 'ad_targeting': value});
        expect(session.adTargeting, isEmpty);
      }
    });
  });
}
