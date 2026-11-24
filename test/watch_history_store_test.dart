import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('saves with PUT to the storefront watch history', () async {
    final requests = <http.Request>[];
    final store = EYZFlowWatchHistoryStore(
      storefrontId: 'sf/1',
      authorization: 'Bearer viewer',
      offerId: 'offer-1',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      }),
      endpoints: const EYZFlowEndpoints(api: 'https://api.test/'),
    );

    await store.save(
      catalogueId: 'cat-1',
      progressSeconds: 612.9,
      completed: false,
    );

    final request = requests.single;
    expect(request.method, 'PUT');
    expect(
      request.url.toString(),
      'https://api.test/v1/content/storefront/sf%2F1/watch-history',
    );
    expect(request.headers['Authorization'], 'Bearer viewer');
    expect(request.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(request.body), {
      'catalogue_id': 'cat-1',
      'progress_seconds': 612,
      'completed': false,
      'offer_id': 'offer-1',
    });
    // Whole seconds, as an int.
    expect((jsonDecode(request.body) as Map)['progress_seconds'], isA<int>());
  });

  test('leaves offer_id out without an offer', () async {
    final bodies = <Object?>[];
    final store = EYZFlowWatchHistoryStore(
      storefrontId: 'sf',
      authorization: 'Bearer viewer',
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body));
        return http.Response('{}', 200);
      }),
    );

    await store.save(
      catalogueId: 'cat-1',
      progressSeconds: 5400,
      completed: true,
    );

    expect(bodies.single, {
      'catalogue_id': 'cat-1',
      'progress_seconds': 5400,
      'completed': true,
    });
  });

  test('a refused save throws with the status only', () async {
    final store = EYZFlowWatchHistoryStore(
      storefrontId: 'sf',
      authorization: 'Bearer secret-token',
      client: MockClient((_) async => http.Response('nope', 401)),
    );

    final Future<void> save = store.save(
      catalogueId: 'cat-1',
      progressSeconds: 30,
      completed: false,
    );

    await expectLater(
      save,
      throwsA(
        isA<WatchHistoryException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => '$e', 'message', isNot(contains('secret'))),
      ),
    );
  });

  test('the recorder saves through it to the watch history', () async {
    final bodies = <Map<String, Object?>>[];
    final recorder = WatchProgressRecorder(
      store: EYZFlowWatchHistoryStore(
        storefrontId: 'sf',
        authorization: 'Bearer viewer',
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, Object?>);
          return http.Response('', 204);
        }),
      ),
      target: VideoplayerSourceTarget(
        EYZFlowSource(
          id: 'stream',
          title: 'Film',
          sourceType: const EYZFlowFilm('cat-1'),
        ),
      ),
    );

    recorder.report(
      const Duration(seconds: 30, milliseconds: 700),
      duration: const Duration(minutes: 90),
    );
    await recorder.flush();

    expect(bodies, [
      {'catalogue_id': 'cat-1', 'progress_seconds': 30, 'completed': false},
    ]);
  });
}
