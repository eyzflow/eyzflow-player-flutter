import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget _app(EYZFlowPlayer player) => MaterialApp(home: player);

EYZFlowPlayer _player({
  required MockClient client,
  required List<EYZFlowSource> mounted,
  List<PlaybackLimitError>? limits,
  VoidCallback? onClose,
}) => EYZFlowPlayer(
  streamId: 'stream-1',
  title: 'Film',
  sourceType: const EYZFlowFilm('cat-1'),
  drmAuthorization: 'Bearer viewer',
  storefrontId: 'sf',
  httpClient: client,
  deviceIdStore: MemoryDeviceIdStore('device-1'),
  onLimitReached: limits?.add,
  onCloseRequested: onClose,
  playerBuilder: (context, target) {
    mounted.add(switch (target) {
      VideoplayerSourceTarget(:final source) => source,
      VideoplayerTrailerTarget(:final source) => source,
    });
    return const SizedBox(key: Key('player'));
  },
);

void main() {
  setUpAll(() => setEYZFlowPlayerLanguage('en'));

  testWidgets('mounts the player with the built access token', (tester) async {
    final mounted = <EYZFlowSource>[];
    final client = MockClient((request) async {
      if (request.method == 'DELETE') return http.Response('', 204);
      return http.Response(jsonEncode({'id': 'ps_1'}), 201);
    });

    await tester.pumpWidget(_app(_player(client: client, mounted: mounted)));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('player')), findsOneWidget);
    final header = mounted.last.drmAccessHeader!;
    final payload = jsonDecode(utf8.decode(base64Decode(header))) as Map;
    expect(payload['parameters'], {
      'storefront_id': 'sf',
      'device_id': 'device-1',
      'playback_session_id': 'ps_1',
    });
    expect(mounted.last.sourceType, const EYZFlowFilm('cat-1'));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a stream limit shows its message instead of the player', (
    tester,
  ) async {
    final mounted = <EYZFlowSource>[];
    final limits = <PlaybackLimitError>[];
    var closed = 0;
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'code': 'STREAM_LIMIT'}), 403),
    );

    await tester.pumpWidget(
      _app(
        _player(
          client: client,
          mounted: mounted,
          limits: limits,
          onClose: () => closed += 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(mounted, isEmpty);
    expect(limits.single.code, PlaybackLimitCode.streamLimit);
    expect(find.textContaining('too many screens'), findsOneWidget);
    await tester.tap(find.text('OK'));
    expect(closed, 1);
  });

  group('watch progress', () {
    late List<http.Request> requests;
    late MockClient client;

    setUp(() {
      requests = [];
      client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'DELETE') return http.Response('', 204);
        if (request.url.path.endsWith('/watch-history')) {
          return http.Response('', 204);
        }
        return http.Response(jsonEncode({'id': 'ps_1'}), 201);
      });
    });

    List<http.Request> watchHistory() =>
        requests.where((r) => r.url.path.endsWith('/watch-history')).toList();

    Future<WatchProgressRecorder?> mount(
      WidgetTester tester, {
      EYZFlowSourceType sourceType = const EYZFlowFilm('cat-1'),
      String? drmAuthorization = 'Bearer viewer',
      String? storefrontId = 'sf',
      bool saveWatchProgress = true,
      WatchProgressStore? watchProgressStore,
      PlayerConfigOverride? config,
    }) async {
      await tester.pumpWidget(
        _app(
          EYZFlowPlayer(
            streamId: 'stream-1',
            title: 'Film',
            sourceType: sourceType,
            drmAuthorization: drmAuthorization,
            storefrontId: storefrontId,
            offerId: 'offer-1',
            saveWatchProgress: saveWatchProgress,
            watchProgressStore: watchProgressStore,
            config: config,
            httpClient: client,
            deviceIdStore: MemoryDeviceIdStore('device-1'),
            playerBuilder: (context, target) =>
                const SizedBox(key: Key('player')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('player')), findsOneWidget);
      return tester
          .widget<VideoplayerFeatureView>(find.byType(VideoplayerFeatureView))
          .watchProgressRecorder;
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('a film saves to the EYZFlow watch history by default', (
      tester,
    ) async {
      final recorder = await mount(tester);

      expect(recorder?.store, isA<EYZFlowWatchHistoryStore>());
      recorder!.report(
        const Duration(seconds: 42),
        duration: const Duration(minutes: 90),
      );
      await tester.runAsync(recorder.flush);

      final request = watchHistory().single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/v1/content/storefront/sf/watch-history');
      expect(request.headers['Authorization'], 'Bearer viewer');
      expect(jsonDecode(request.body), {
        'catalogue_id': 'cat-1',
        'progress_seconds': 42,
        'completed': false,
        'offer_id': 'offer-1',
      });
      await unmount(tester);
    });

    testWidgets('the config sets when a film counts as watched', (
      tester,
    ) async {
      final recorder = await mount(
        tester,
        config: const PlayerConfigOverride(
          watchProgress: PlayerWatchProgressConfig(completedPercent: 80),
        ),
      );

      expect(recorder!.completedPercent, 80);
      recorder.report(
        const Duration(minutes: 81),
        duration: const Duration(minutes: 100),
      );
      await tester.runAsync(recorder.flush);

      expect(
        jsonDecode(watchHistory().single.body),
        containsPair('completed', true),
      );
      await unmount(tester);
    });

    testWidgets('saveWatchProgress: false saves nothing', (tester) async {
      final own = _Store();
      final recorder = await mount(
        tester,
        saveWatchProgress: false,
        watchProgressStore: own,
      );

      expect(recorder, isNull);
      await unmount(tester);
      expect(watchHistory(), isEmpty);
      expect(own.saves, isEmpty);
    });

    testWidgets("the app's own store replaces the watch history", (
      tester,
    ) async {
      final own = _Store();
      final recorder = await mount(tester, watchProgressStore: own);

      expect(recorder?.store, same(own));
      recorder!.report(const Duration(seconds: 42));
      await tester.runAsync(recorder.flush);

      expect(own.saves, [('cat-1', 42.0, false)]);
      expect(watchHistory(), isEmpty);
      await unmount(tester);
    });

    for (final (name, auth, storefront) in [
      ('no authorization', null, 'sf'),
      ('an empty authorization', '', 'sf'),
      ('no storefront', 'Bearer viewer', null),
    ]) {
      testWidgets('$name never calls the watch history', (tester) async {
        final recorder = await mount(
          tester,
          drmAuthorization: auth,
          storefrontId: storefront,
        );

        expect(recorder, isNull);
        await unmount(tester);
        expect(watchHistory(), isEmpty);
      });
    }

    testWidgets('a trailer saves nothing', (tester) async {
      final recorder = await mount(
        tester,
        sourceType: const EYZFlowTrailer('cat-1'),
      );

      expect(recorder, isNull);
      await unmount(tester);
      expect(watchHistory(), isEmpty);
    });
  });
}

class _Store implements WatchProgressStore {
  final saves = <(String, double, bool)>[];

  @override
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  }) async => saves.add((catalogueId, progressSeconds, completed));
}
