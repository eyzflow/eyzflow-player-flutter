import 'dart:convert';

import 'package:eyzflow_player/src/core/api.dart';
import 'package:eyzflow_player/src/core/player_license.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok([Map<String, Object?> over = const {}]) => http.Response(
  jsonEncode({
    'token': 'plk1.a.b',
    'expires_in': 900,
    'refresh_after': 600,
    'mode': 'enforce',
    'would_refuse': null,
    'analytics': {'enabled': true, 'heartbeat_interval_seconds': 60},
    ...over,
  }),
  200,
);

PlayerLicense _licence(String token) =>
    PlayerLicense(token: token, mode: PlayerKeyMode.enforce);

const _app = PlayerApp(
  platform: PlayerPlatform.androidTv,
  id: 'com.example.tv',
);

void main() {
  group('PlayerLicenseClient.acquire', () {
    test('posts the key with the app and reads the licence', () async {
      late http.Request sent;
      final client = PlayerLicenseClient(
        client: MockClient((request) async {
          sent = request;
          return _ok();
        }),
      );

      final licence = await client.acquire(
        const PlayerLicenseRequest(key: 'pk_x', streamId: 's1', app: _app),
      );

      expect(licence.token, 'plk1.a.b');
      expect(licence.expiresIn, const Duration(seconds: 900));
      expect(licence.refreshAfter, const Duration(seconds: 600));
      expect(licence.mode, PlayerKeyMode.enforce);
      expect(licence.wouldRefuse, isNull);
      expect(licence.analyticsEnabled, isTrue);
      expect(licence.heartbeatInterval, const Duration(seconds: 60));
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'https://api.eyzflow.com/v1/player/license');
      expect(jsonDecode(sent.body), {
        'key': 'pk_x',
        'stream_id': 's1',
        'player_version': eyzflowPlayerVersion,
        'app': {'platform': 'androidtv', 'id': 'com.example.tv'},
      });
    });

    test('reads defaults when the answer leaves fields out', () async {
      final client = PlayerLicenseClient(
        client: MockClient(
          (_) async => http.Response(jsonEncode({'token': 't'}), 200),
        ),
      );

      final licence = await client.acquire(
        const PlayerLicenseRequest(key: 'pk', streamId: 's'),
      );

      expect(licence.mode, PlayerKeyMode.off);
      expect(licence.analyticsEnabled, isFalse);
      expect(licence.refreshAfter, const Duration(seconds: 600));
      expect(licence.heartbeatInterval, const Duration(seconds: 60));
    });

    test('names would_refuse in log mode', () async {
      final client = PlayerLicenseClient(
        client: MockClient(
          (_) async =>
              _ok({'mode': 'log', 'would_refuse': 'DOMAIN_NOT_ALLOWED'}),
        ),
      );

      final licence = await client.acquire(
        const PlayerLicenseRequest(key: 'pk', streamId: 's'),
      );

      expect(licence.mode, PlayerKeyMode.log);
      expect(licence.wouldRefuse, PlayerLicenseCode.domainNotAllowed);
    });

    test('throws a PlayerLicenseException with a viewer message', () async {
      final client = PlayerLicenseClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 'PLAYER_KEY_INVALID', 'message': 'x'}),
            403,
          ),
        ),
      );

      await expectLater(
        client.acquire(const PlayerLicenseRequest(key: 'pk', streamId: 's')),
        throwsA(
          isA<PlayerLicenseException>()
              .having(
                (e) => e.error.code,
                'code',
                PlayerLicenseCode.playerKeyInvalid,
              )
              .having(
                (e) => e.error.message,
                'message',
                'This player is not set up correctly (invalid player key).',
              ),
        ),
      );
    });

    test('a refused app reads as a licence refusal', () async {
      final client = PlayerLicenseClient(
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'code': 'APP_NOT_ALLOWED'}), 403),
        ),
      );

      await expectLater(
        client.acquire(const PlayerLicenseRequest(key: 'pk', streamId: 's')),
        throwsA(
          isA<PlayerLicenseException>().having(
            (e) => e.error.code,
            'code',
            PlayerLicenseCode.appNotAllowed,
          ),
        ),
      );
    });

    test('throws a plain error when the check cannot be made', () async {
      for (final response in [
        http.Response('bad gateway', 502),
        http.Response(jsonEncode({'code': 'RATE_LIMITED'}), 429),
      ]) {
        final client = PlayerLicenseClient(
          client: MockClient((_) async => response),
        );
        await expectLater(
          client.acquire(const PlayerLicenseRequest(key: 'pk', streamId: 's')),
          throwsA(isNot(isA<PlayerLicenseException>())),
        );
      }
    });
  });

  group('PlayerLicenseSession', () {
    test(
      'renews after refresh_after and retries a failed renewal a minute later',
      () {
        fakeAsync((async) {
          final answers = <Object>[
            _licence('t1'),
            Exception('offline'),
            _licence('t2'),
          ];
          var calls = 0;
          late PlayerLicenseSession session;
          PlayerLicenseSession.start(
            const PlayerLicenseRequest(key: 'pk', streamId: 's'),
            acquire: (_) async {
              final answer = answers[calls++];
              if (answer is PlayerLicense) return answer;
              throw answer;
            },
            onRefused: (_) => fail('not refused'),
          ).then((value) => session = value);
          async.flushMicrotasks();
          expect(session.token, 't1');

          async.elapse(const Duration(seconds: 600));
          expect(session.token, 't1');
          async.elapse(const Duration(seconds: 60));
          expect(session.token, 't2');
          session.stop();
        });
      },
    );

    test('reports a refusal once and stops', () {
      fakeAsync((async) {
        var calls = 0;
        final refusals = <PlayerLicenseError>[];
        PlayerLicenseSession.start(
          const PlayerLicenseRequest(key: 'pk', streamId: 's'),
          acquire: (_) async {
            calls += 1;
            if (calls == 1) return _licence('t1');
            throw PlayerLicenseException(
              PlayerLicenseError.of(PlayerLicenseCode.playerKeyInvalid),
            );
          },
          onRefused: refusals.add,
        );
        async.elapse(const Duration(seconds: 600 * 3));

        expect(refusals.map((e) => e.code), [
          PlayerLicenseCode.playerKeyInvalid,
        ]);
        expect(calls, 2);
      });
    });

    test('never renews sooner than ten seconds', () {
      fakeAsync((async) {
        var calls = 0;
        PlayerLicenseSession.start(
          const PlayerLicenseRequest(key: 'pk', streamId: 's'),
          acquire: (_) async {
            calls += 1;
            return const PlayerLicense(token: 't', refreshAfter: Duration.zero);
          },
          onRefused: (_) {},
        ).then((session) {
          async.elapse(const Duration(seconds: 9));
          expect(calls, 1);
          async.elapse(const Duration(seconds: 1));
          expect(calls, 2);
          session.stop();
        });
        async.flushMicrotasks();
      });
    });
  });
}
