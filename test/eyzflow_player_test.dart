import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget _app(EyzflowPlayer player) => MaterialApp(home: player);

EyzflowPlayer _player({
  required MockClient client,
  required List<EyzflowSource> mounted,
  List<PlaybackLimitError>? limits,
  VoidCallback? onClose,
}) => EyzflowPlayer(
  streamId: 'stream-1',
  title: 'Film',
  sourceType: const EyzflowFilm('cat-1'),
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
  setUpAll(() => setEyzflowPlayerLanguage('en'));

  testWidgets('mounts the player with the built access token', (tester) async {
    final mounted = <EyzflowSource>[];
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
    expect(mounted.last.sourceType, const EyzflowFilm('cat-1'));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a stream limit shows its message instead of the player', (
    tester,
  ) async {
    final mounted = <EyzflowSource>[];
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
}
