import 'dart:convert';

import 'package:eyzflow_player/src/core/access_token.dart';
import 'package:eyzflow_player/src/core/device_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds the base64 JSON the licence gate reads, without nulls', () {
    final header = buildAccessToken(
      'Bearer viewer',
      parameters: {
        'source': 'internal',
        'storefront_id': 'sf',
        'device_id': 'd',
        'playback_session_id': null,
        'player_token': 'plk1.a.b',
      },
    );

    expect(jsonDecode(utf8.decode(base64Decode(header))), {
      'headers': {'authorization': 'Bearer viewer'},
      'parameters': {
        'source': 'internal',
        'storefront_id': 'sf',
        'device_id': 'd',
        'player_token': 'plk1.a.b',
      },
    });
  });

  test('matches the web player for ASCII payloads (btoa)', () {
    // btoa(JSON.stringify({headers:{authorization:"a"},parameters:{}}))
    expect(
      buildAccessToken('a'),
      'eyJoZWFkZXJzIjp7ImF1dGhvcml6YXRpb24iOiJhIn0sInBhcmFtZXRlcnMiOnt9fQ==',
    );
  });

  test('UUIDs are version 4', () {
    final id = newUuidV4();
    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(newUuidV4(), isNot(id));
  });

  test('the memory store keeps one id', () async {
    final store = MemoryDeviceIdStore();
    expect(await store.read(), await store.read());
    expect(await MemoryDeviceIdStore('fixed').read(), 'fixed');
  });
}
