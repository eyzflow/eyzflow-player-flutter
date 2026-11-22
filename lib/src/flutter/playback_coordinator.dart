import 'dart:async';

import '../player/playback_event.dart';
import 'package:flutter/foundation.dart';

import '../core/access_token.dart';
import '../core/analytics/collector.dart';
import '../core/analytics/transport.dart';
import '../core/api.dart';
import '../core/device_id.dart';
import '../core/playback_session.dart';
import '../core/player_license.dart';
import 'event_adapter.dart';

/// Why the player stopped or did not start, as the error screen shows it.
sealed class EYZFlowPlayerFailure {
  const EYZFlowPlayerFailure();

  /// The viewer-facing text.
  String get message;
}

/// The player key check refused the app.
final class EYZFlowLicenseFailure extends EYZFlowPlayerFailure {
  const EYZFlowLicenseFailure(this.error);

  final PlayerLicenseError error;

  @override
  String get message => error.message;
}

/// A stream or device limit, or the session was ended elsewhere.
final class EYZFlowLimitFailure extends EYZFlowPlayerFailure {
  const EYZFlowLimitFailure(this.error);

  final PlaybackLimitError error;

  @override
  String get message => error.message;
}

/// Where the player is before and around playback.
sealed class EYZFlowPlayerStatus {
  const EYZFlowPlayerStatus();
}

/// Checking the key and opening the session.
final class EYZFlowPlayerLoading extends EYZFlowPlayerStatus {
  const EYZFlowPlayerLoading();
}

/// Mount the player with this DRM `access-token` (null for a stream that
/// plays without DRM).
final class EYZFlowPlayerReady extends EYZFlowPlayerStatus {
  const EYZFlowPlayerReady(
    this.drmAccessHeader, {
    this.planAds,
    this.adTargeting = const {},
  });

  final String? drmAccessHeader;

  /// The playback session's answer: whether the viewer's plan plays ads
  /// ([PlaybackSession.ads]). False plays none; null (no session, an older
  /// backend, a failed request) leaves it to the player config.
  final bool? planAds;

  /// [PlaybackSession.adTargeting], for the ad tag's `cust_params`.
  final Map<String, String> adTargeting;
}

/// Show the failure; the player is not (or no longer) mounted.
final class EYZFlowPlayerFailed extends EYZFlowPlayerStatus {
  const EYZFlowPlayerFailed(this.failure);

  final EYZFlowPlayerFailure failure;
}

/// What one playback is asked to do.
final class PlaybackCoordinatorConfig {
  const PlaybackCoordinatorConfig({
    required this.streamId,
    required this.isProtected,
    this.playerKey,
    this.configId,
    this.drmAuthorization,
    this.storefrontId,
    this.drmParameters = const {},
    this.deviceName,
    this.app,
    this.platform,
    this.analytics = true,
  });

  final String streamId;

  /// A feature-length source: DRM. A trailer plays without it, but a
  /// storefront viewer's trailer still opens a playback session (for the
  /// plan's ads answer), and so counts against the plan's limits.
  final bool isProtected;
  final String? playerKey;
  final String? configId;

  /// The viewer's `Authorization`, e.g. `Bearer <token>`.
  final String? drmAuthorization;
  final String? storefrontId;

  /// Extra DRM access-token parameters, e.g. `{'source': 'internal'}`.
  final Map<String, Object?> drmParameters;
  final String? deviceName;
  final PlayerApp? app;
  final PlayerPlatform? platform;

  /// False turns beats off even when the key has analytics on.
  final bool analytics;
}

/// One playback's EYZFlow side, in the web player's order (`use-shaka.ts`):
/// player key check, then playback session, then the DRM access token; while
/// playing, the token renewal, the session heartbeat and the beats; on close,
/// the final beat and the session's end. The widget mounts the player when
/// [status] is [EYZFlowPlayerReady] and feeds its events to [onPlaybackEvent].
final class PlaybackCoordinator extends ChangeNotifier {
  PlaybackCoordinator({
    required this.config,
    required this._licenseClient,
    required this._sessionClient,
    required this._beatSender,
    required this._deviceIdStore,
    this.onLimitReached,
    this.onLicenseError,
    this.onError,
    this._now,
  });

  final PlaybackCoordinatorConfig config;
  final PlayerLicenseClient _licenseClient;
  final PlaybackSessionClient _sessionClient;
  final BeatSender _beatSender;
  final DeviceIdStore _deviceIdStore;
  final MonotonicClock? _now;
  final ValueChanged<PlaybackLimitError>? onLimitReached;
  final ValueChanged<PlayerLicenseError>? onLicenseError;
  final ValueChanged<String>? onError;

  EYZFlowPlayerStatus _status = const EYZFlowPlayerLoading();
  PlayerLicenseSession? _license;
  BeatTransport? _transport;
  PlaybackEventAdapter? _adapter;
  PlaybackSessionTarget? _sessionTarget;
  String? _sessionId;
  Timer? _heartbeat;
  var _heartbeatInFlight = false;
  var _disposed = false;
  Future<void>? _ending;

  EYZFlowPlayerStatus get status => _status;

  /// The player token, while the key check has granted one.
  String? get playerToken => _license?.token;

  /// The beat transport, while analytics are on. For the example app's log.
  @visibleForTesting
  BeatTransport? get transport => _transport;

  Future<void> start() async {
    final String deviceId = await _readDeviceId();
    if (_disposed) return;

    final String? key = config.playerKey;
    if (key != null && key.isNotEmpty) {
      try {
        _license = await PlayerLicenseSession.start(
          PlayerLicenseRequest(
            key: key,
            streamId: config.streamId,
            configId: config.configId,
            app: config.app,
          ),
          acquire: _licenseClient.acquire,
          onRefused: _onLicenseRefusedWhilePlaying,
        );
      } on PlayerLicenseException catch (refusal) {
        return _fail(EYZFlowLicenseFailure(refusal.error));
      } on Object catch (error) {
        // The check could not be made: play on without a token, as the web
        // player does. The DRM gate decides.
        debugPrint('[eyzflow-player] licence check failed: $error');
      }
      if (_disposed) return _endAll();
      final PlayerLicense? license = _license?.current;
      if (license != null && config.analytics && license.analyticsEnabled) {
        _startAnalytics(license.heartbeatInterval);
      }
    }

    final String? authorization = config.drmAuthorization;
    final bool signedIn = authorization != null && authorization.isNotEmpty;
    final String? storefrontId = config.storefrontId;
    final bool hasStorefront = storefrontId != null && storefrontId.isNotEmpty;

    // A storefront viewer: the session counts this stream against the plan's
    // limits and says whether the plan plays ads. Opened for clear streams
    // too, for the ads answer (as the web player does).
    PlaybackSession? session;
    if (signedIn && hasStorefront) {
      final target = PlaybackSessionTarget(
        storefrontId: storefrontId,
        authorization: authorization,
        deviceId: deviceId,
      );
      try {
        session = await _sessionClient.open(
          target,
          streamId: config.streamId,
          platform: config.platform ?? PlayerPlatform.android,
          deviceName: config.deviceName,
        );
        _sessionTarget = target;
        _sessionId = session.id;
        if (_disposed) {
          await _endAll();
          return;
        }
        final String? id = session.id;
        if (id != null) _startHeartbeat(target, id, session.heartbeatInterval);
      } on PlaybackLimitException catch (limit) {
        return _fail(EYZFlowLimitFailure(limit.error));
      } on Object catch (error) {
        // Not a limit: carry on. The licence request enforces limits, and
        // ads follow the player config.
        debugPrint('[eyzflow-player] playback session failed: $error');
      }
    }

    String? accessHeader;
    if (config.isProtected && signedIn) {
      final String? sessionId = session?.id;
      final parameters = <String, Object?>{
        ...config.drmParameters,
        if (hasStorefront) 'storefront_id': storefrontId,
        'device_id': deviceId,
        'playback_session_id': ?sessionId,
        // Fixed for this load: the native players take the header once.
        'player_token': _license?.token,
      };
      accessHeader = buildAccessToken(authorization, parameters: parameters);
    }

    if (_disposed) return _endAll();
    _setStatus(
      EYZFlowPlayerReady(
        accessHeader,
        planAds: session?.ads,
        adTargeting: session?.adTargeting ?? const {},
      ),
    );
  }

  /// Every event the player reports.
  void onPlaybackEvent(PlaybackEvent event) {
    _adapter?.add(event);
    if (event case PlaybackError(:final message)) {
      final failure = _failureIn(message);
      if (failure != null) {
        unawaited(_fail(failure));
        return;
      }
      onError?.call(message);
    }
  }

  /// The app went to the background: send what there is, it may not return.
  void onBackgrounded() {
    final transport = _transport;
    if (transport != null) unawaited(transport.beat());
  }

  void _startAnalytics(Duration interval) {
    final collector = BeatCollector(now: _now);
    _adapter = PlaybackEventAdapter(collector);
    _transport = BeatTransport(
      collector: collector,
      token: () => _license?.token,
      streamId: config.streamId,
      interval: interval,
      send: _beatSender,
      drm: config.isProtected && config.drmAuthorization != null
          ? config.platform?.drmName
          : 'none',
      platform: config.platform,
    )..start();
  }

  void _startHeartbeat(
    PlaybackSessionTarget target,
    String sessionId,
    Duration interval,
  ) {
    _heartbeat = Timer.periodic(interval, (_) async {
      if (_heartbeatInFlight || _disposed) return;
      _heartbeatInFlight = true;
      try {
        final alive = await _sessionClient.heartbeat(target, sessionId);
        if (!alive && !_disposed) {
          await _fail(
            const EYZFlowLimitFailure(
              PlaybackLimitError(
                code: PlaybackLimitCode.playbackSessionEnded,
                message: 'Playback was stopped from another device.',
              ),
            ),
          );
        }
      } finally {
        _heartbeatInFlight = false;
      }
    });
  }

  void _onLicenseRefusedWhilePlaying(PlayerLicenseError error) {
    // Only an enforcing organisation stops a playback already under way.
    if (_license?.current.mode != PlayerKeyMode.enforce) return;
    unawaited(_fail(EYZFlowLicenseFailure(error)));
  }

  /// A DRM licence refused by the limit or site check names its code in the
  /// error text, when the platform passes the server's body on.
  static EYZFlowPlayerFailure? _failureIn(String message) {
    for (final code in PlayerLicenseCode.values) {
      if (message.contains(code.wireName)) {
        return EYZFlowLicenseFailure(PlayerLicenseError.of(code));
      }
    }
    for (final code in PlaybackLimitCode.values) {
      if (message.contains(code.wireName)) {
        return EYZFlowLimitFailure(
          PlaybackLimitError(code: code, message: code.message),
        );
      }
    }
    return null;
  }

  Future<void> _fail(EYZFlowPlayerFailure failure) async {
    if (_status is EYZFlowPlayerFailed || _disposed) return;
    _setStatus(EYZFlowPlayerFailed(failure));
    switch (failure) {
      case EYZFlowLicenseFailure(:final error):
        onLicenseError?.call(error);
      case EYZFlowLimitFailure(:final error):
        onLimitReached?.call(error);
    }
    onError?.call(failure.message);
    await _endAll();
  }

  /// Stops renewal, heartbeat and beats (with a final beat) and closes the
  /// session. Once.
  Future<void> _endAll() => _ending ??= () async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _license?.stop();
    final transport = _transport;
    final target = _sessionTarget;
    final sessionId = _sessionId;
    _sessionId = null;
    await Future.wait([
      if (transport != null) transport.stop(),
      if (target != null && sessionId != null)
        _sessionClient.close(target, sessionId),
    ]);
  }();

  Future<String> _readDeviceId() async {
    try {
      return await _deviceIdStore.read();
    } on Object catch (error) {
      debugPrint('[eyzflow-player] device id unavailable: $error');
      return MemoryDeviceIdStore().read();
    }
  }

  void _setStatus(EYZFlowPlayerStatus next) {
    if (_disposed) return;
    _status = next;
    notifyListeners();
  }

  /// Ends everything; the returned future completes once the final beat and
  /// the session's close were sent.
  Future<void> close() {
    _disposed = true;
    return _endAll();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
