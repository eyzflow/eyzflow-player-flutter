import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../device_id.dart';
import 'beat.dart';
import 'collector.dart';

/// Sends one beat. True when it was delivered, or refused for good (400, 401,
/// 413: a resend would be refused too); false to keep its errors for the next.
typedef BeatSender = Future<bool> Function(Beat beat);

/// `POST /v1/player/beat`. The path avoids the word "analytics", which content
/// blockers stop on the web.
final class HttpBeatSender {
  HttpBeatSender({
    http.Client? client,
    this.endpoints = const EYZFlowEndpoints(),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final EYZFlowEndpoints endpoints;

  Future<bool> call(Beat beat) async {
    try {
      final response = await _client.post(
        endpoints.apiUri('/v1/player/beat'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(beat.toJson()),
      );
      final status = response.statusCode;
      return (status >= 200 && status < 300) ||
          status == 400 ||
          status == 401 ||
          status == 413;
    } on Object {
      return false;
    }
  }

  void close() => _client.close();
}

/// Sends one impression's beats: at once on the first frame and on errors,
/// then every heartbeat interval, on [beat] calls from the host (the app
/// going to the background) and a final one on [stop]. Each beat carries the
/// counters so far and a growing sequence number, so the server keeps the
/// newest and ignores repeats.
final class BeatTransport {
  BeatTransport({
    required BeatCollector collector,
    required this._token,
    required this.streamId,
    required this.interval,
    required this._send,
    this.autoplay = true,
    this.isLive = false,
    this.drm,
    this.platform,
    this.playerVersion = eyzflowPlayerVersion,
    String? impressionId,
    DateTime Function()? wallClock,
  }) : _collector = collector,
       impressionId = impressionId ?? newUuidV4(),
       startedAt = (wallClock ?? DateTime.now)().millisecondsSinceEpoch {
    collector.onMilestone = () => unawaited(beat());
  }

  final BeatCollector _collector;
  final String? Function() _token;
  final BeatSender _send;
  final String streamId;
  final Duration interval;
  final bool autoplay;
  final bool isLive;
  final String? drm;
  final PlayerPlatform? platform;
  final String playerVersion;
  final String impressionId;
  final int startedAt;
  var _seq = 0;
  Timer? _timer;
  var _stopped = false;

  bool get isStopped => _stopped;

  void start() {
    if (_timer != null || _stopped) return;
    const floor = Duration(seconds: 10);
    _timer = Timer.periodic(
      interval < floor ? floor : interval,
      (_) => unawaited(beat()),
    );
  }

  /// Sends the last beat and stops. Safe to call more than once.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _collector.onMilestone = null;
    await _beat(isFinal: true);
  }

  /// Sends a beat now, unless stopped.
  Future<void> beat() async {
    if (_stopped) return;
    await _beat(isFinal: false);
  }

  Future<void> _beat({required bool isFinal}) async {
    final token = _token();
    if (token == null) return;
    final errors = _collector.takeErrors();
    final sent = await _send(
      Beat(
        token: token,
        sid: impressionId,
        seq: ++_seq,
        startedAt: startedAt,
        isFinal: isFinal,
        streamId: streamId,
        isLive: isLive,
        autoplay: autoplay,
        drm: drm,
        playerVersion: playerVersion,
        platform: platform?.wireName,
        metrics: _collector.metrics(),
        errors: errors,
      ),
    );
    if (!sent && errors.isNotEmpty) _collector.returnErrors(errors);
  }
}
