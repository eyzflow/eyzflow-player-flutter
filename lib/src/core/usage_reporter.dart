import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'device_id.dart';

/// The longest report the backend takes, in seconds.
const int maxUsageReportSeconds = 120;

/// How often a playing film reports.
const Duration usageReportInterval = Duration(seconds: 30);

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// What a usage report counts against: the viewer, their storefront and the
/// offer played.
final class UsageTarget {
  const UsageTarget({
    required this.storefrontId,
    required this.authorization,
    required this.offerId,
    this.catalogueId,
  });

  final String storefrontId;

  /// The viewer's `Authorization` value, e.g. `Bearer <token>`.
  final String authorization;

  /// The offer (film or episode) played.
  final String offerId;

  /// The catalogue entry played; left out of the report when it is not a
  /// UUID.
  final String? catalogueId;
}

/// How a report went.
enum UsageSendResult {
  /// Counted.
  ok,

  /// Not counted yet: send the seconds again with the next report.
  retry,

  /// Refused; sending the same report again would not help.
  drop,
}

/// Sends one report: the target and the `playback-events` body.
typedef UsageSender =
    Future<UsageSendResult> Function(
      UsageTarget target,
      Map<String, Object?> body,
    );

/// `POST /v1/content/storefront/:storefront_id/playback-events`.
final class HttpUsageSender {
  HttpUsageSender({
    http.Client? client,
    this.endpoints = const EYZFlowEndpoints(),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final EYZFlowEndpoints endpoints;

  Future<UsageSendResult> call(
    UsageTarget target,
    Map<String, Object?> body,
  ) async {
    try {
      final response = await _client.post(
        endpoints.apiUri(
          '/v1/content/storefront/${Uri.encodeComponent(target.storefrontId)}'
          '/playback-events',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': target.authorization,
        },
        body: jsonEncode(body),
      );
      final status = response.statusCode;
      if (status >= 200 && status < 300) return UsageSendResult.ok;
      // A bad body, a signed-out viewer or an unknown offer: the same report
      // would be refused again.
      if (const {400, 401, 403, 404}.contains(status)) {
        return UsageSendResult.drop;
      }
      return UsageSendResult.retry;
    } on Object {
      return UsageSendResult.retry;
    }
  }

  void close() => _client.close();
}

/// Reports the seconds of a film the viewer watched, for licensor royalties:
/// every 30 s while it plays, at once on a pause, at the end and when the app
/// goes to the background, and a last time on [stop]. Each report carries
/// the seconds since the previous one (at most 120) and one session id for
/// the whole playback. Seconds a report could not deliver go with the next
/// one. The web player's `UsageReporter`.
///
/// The played time comes from a `BeatCollector`, so ads, pauses, seeks and
/// stalls do not count.
final class UsageReporter {
  UsageReporter({
    required this.target,
    required this._playedMs,
    required this._send,
    this.interval = usageReportInterval,
    String? sessionId,
  }) : sessionId = sessionId ?? newUuidV4();

  final UsageTarget target;
  final String sessionId;
  final Duration interval;
  final int Function() _playedMs;
  final UsageSender _send;

  /// Played milliseconds already moved into [_pendingMs].
  var _takenMs = 0;

  /// Milliseconds not reported yet.
  var _pendingMs = 0;
  var _inFlight = false;
  Timer? _timer;
  var _stopped = false;

  bool get isStopped => _stopped;

  void start() {
    if (_timer != null || _stopped) return;
    _timer = Timer.periodic(interval, (_) => unawaited(report()));
  }

  /// Sends the last report and stops. Safe to call more than once.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _report(isFinal: true);
  }

  /// Reports now, unless stopped or a report is still on its way.
  Future<void> report() async {
    if (_stopped) return;
    await _report(isFinal: false);
  }

  Future<void> _report({required bool isFinal}) async {
    final int played;
    try {
      played = _playedMs();
    } on Object {
      return;
    }
    if (played > _takenMs) {
      _pendingMs += played - _takenMs;
      _takenMs = played;
    }
    // One report at a time, so a slow one is not overtaken; the last one
    // goes out regardless.
    if (_inFlight && !isFinal) return;
    final int seconds = (_pendingMs ~/ 1000).clamp(0, maxUsageReportSeconds);
    if (seconds < 1) return;
    _pendingMs -= seconds * 1000;

    final String? catalogueId = target.catalogueId;
    final body = <String, Object?>{
      'offer_id': target.offerId,
      if (catalogueId != null && _uuid.hasMatch(catalogueId))
        'catalogue_id': catalogueId,
      'session_id': sessionId,
      'watched_seconds': seconds,
      'is_trailer': false,
    };
    _inFlight = true;
    UsageSendResult result;
    try {
      result = await _send(target, body);
    } on Object {
      result = UsageSendResult.retry;
    } finally {
      _inFlight = false;
    }
    if (result == UsageSendResult.retry) _pendingMs += seconds * 1000;
  }
}
