import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'player_log.dart';
import '../l10n/streaming_l10n.dart';

/// A licence acquisition failure, safe to surface as playback failure copy.
///
/// The message never contains challenge bytes or a licence response body.
final class WidevineLicenseException implements Exception {
  const WidevineLicenseException(this.message);

  final String message;

  @override
  String toString() => 'WidevineLicenseException: $message';
}

/// Exchanges a Widevine challenge for a licence with the upstream UAT proxy.
///
/// Intentionally minimal: one bounded POST, no retry, metadata-only logging —
/// except that debug builds also log a refused licence's error body (see the
/// package README). AVPlay blocks the platform thread while the licence
/// callback runs, so extra work here can stall the TV.
final class WidevineLicenseClient {
  WidevineLicenseClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration timeout;

  /// Counts exchanges so a mid-playback renewal is distinguishable from the
  /// first licence. Playback that dies after a few seconds usually dies here.
  var _exchangeCount = 0;

  Future<Uint8List> fetchLicense(
    Uint8List challenge, {
    required Uri licenseUri,
    required String drmAccessHeader,
  }) async {
    final int exchange = ++_exchangeCount;
    logPlayback(
      'licence $exchange: ${challenge.length} byte challenge '
      'at ${DateTime.now().toIso8601String()}',
    );
    try {
      final http.Response response = await _httpClient
          .post(
            licenseUri,
            headers: <String, String>{
              'Content-Type': 'application/octet-stream',
              // EYZFlow rejects an unauthenticated acquire with 401. Sending
              // the credential from Dart is only possible because AVPlay
              // hands us the challenge instead of fetching the licence itself.
              'access-token': drmAccessHeader,
            },
            body: challenge,
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        logPlayback(
          'licence $exchange refused status=${response.statusCode}',
          error: const WidevineLicenseException('refused'),
        );
        // Debug builds only (logPlayback drops non-error lines in release).
        // A refusal is the server's JSON error, never a licence, so its
        // message is what diagnoses an EYZFlow 500 — the status alone
        // cannot. A granted body is never logged: that one is key material.
        logPlayback(
          'licence $exchange refusal body: '
          '${_truncate(utf8.decode(response.bodyBytes, allowMalformed: true))}',
        );
        throw WidevineLicenseException(
          'Licence request failed with status ${response.statusCode}.',
        );
      }

      logPlayback(
        'licence $exchange granted: ${response.bodyBytes.length} bytes',
      );
      return response.bodyBytes;
    } on TimeoutException {
      logPlayback(
        'licence $exchange timed out',
        error: const WidevineLicenseException('timeout'),
      );
      throw WidevineLicenseException(streamingL10n.licenceRequestTimedOut);
    } on http.ClientException catch (error) {
      logPlayback('licence $exchange transport failure', error: error);
      throw WidevineLicenseException(streamingL10n.licenceRequestNotSent);
    }
  }

  void close() => _httpClient.close();

  static String _truncate(String body) =>
      body.length <= 500 ? body : '${body.substring(0, 500)}…';
}
