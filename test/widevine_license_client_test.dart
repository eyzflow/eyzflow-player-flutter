import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eyzflow_player/src/player/widevine_license_client.dart';

final Uint8List _challenge = Uint8List.fromList(<int>[1, 2, 3, 4]);
final Uri _licenseUri = Uri.parse(
  'https://api.eyzflow.com/v1/drm/film-a/widevine/acquire',
);
const String _accessHeader = 'base64-drm-payload';

void main() {
  test('diagnostics never extract or log challenge payload bytes', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    final client = WidevineLicenseClient(
      httpClient: MockClient((_) async => http.Response.bytes([9], 200)),
    );
    addTearDown(client.close);
    await client.fetchLicense(
      Uint8List.fromList([0x12, 0x10, ...List.filled(16, 0xab)]),
      licenseUri: _licenseUri,
      drmAccessHeader: 'SECRET_HEADER',
    );
    expect(lines.join(), isNot(contains('abababababababababababababababab')));
    expect(lines.join(), isNot(contains('SECRET_HEADER')));
    expect(lines.join(), contains('granted'));
  });
  test(
    'posts the raw challenge to the upstream proxy and returns raw bytes',
    () async {
      http.Request? captured;
      final WidevineLicenseClient client = WidevineLicenseClient(
        httpClient: MockClient((http.Request request) async {
          captured = request;
          return http.Response.bytes(<int>[9, 8, 7], 200);
        }),
      );

      final Uint8List license = await client.fetchLicense(
        _challenge,
        licenseUri: _licenseUri,
        drmAccessHeader: _accessHeader,
      );

      expect(license, <int>[9, 8, 7]);
      expect(captured!.method, 'POST');
      expect(captured!.url, _licenseUri);
      expect(captured!.bodyBytes, <int>[1, 2, 3, 4]);
      expect(captured!.headers['Content-Type'], 'application/octet-stream');
      expect(captured!.headers['access-token'], _accessHeader);
    },
  );

  test(
    'a non-success status fails without leaking the response body',
    () async {
      final WidevineLicenseClient client = WidevineLicenseClient(
        httpClient: MockClient((http.Request request) async {
          return http.Response('denied: secret-key-material', 403);
        }),
      );

      await expectLater(
        client.fetchLicense(
          _challenge,
          licenseUri: _licenseUri,
          drmAccessHeader: _accessHeader,
        ),
        throwsA(
          isA<WidevineLicenseException>().having(
            (WidevineLicenseException error) => error.message,
            'message',
            allOf(contains('403'), isNot(contains('secret-key-material'))),
          ),
        ),
      );
    },
  );

  test('a transport failure becomes a licence exception', () async {
    final WidevineLicenseClient client = WidevineLicenseClient(
      httpClient: MockClient((http.Request request) async {
        throw http.ClientException('socket closed');
      }),
    );

    await expectLater(
      client.fetchLicense(
        _challenge,
        licenseUri: _licenseUri,
        drmAccessHeader: _accessHeader,
      ),
      throwsA(isA<WidevineLicenseException>()),
    );
  });

  test('the request is bounded by the timeout', () async {
    final WidevineLicenseClient client = WidevineLicenseClient(
      timeout: const Duration(milliseconds: 20),
      httpClient: MockClient((http.Request request) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response.bytes(<int>[1], 200);
      }),
    );

    await expectLater(
      client.fetchLicense(
        _challenge,
        licenseUri: _licenseUri,
        drmAccessHeader: _accessHeader,
      ),
      throwsA(
        isA<WidevineLicenseException>().having(
          (WidevineLicenseException error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test('the default timeout is the documented 15 seconds', () {
    expect(
      WidevineLicenseClient(
        httpClient: MockClient((_) async => http.Response('', 200)),
      ).timeout,
      const Duration(seconds: 15),
    );
  });
}
