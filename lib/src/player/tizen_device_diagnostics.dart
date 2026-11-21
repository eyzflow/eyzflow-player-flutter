import 'package:get_it/get_it.dart';
import 'package:device_info_plus_tizen/device_info_plus_tizen.dart';

import 'player_log.dart';

/// Package-owned locator for streaming-surface runtime services.
///
/// Kept separate from any app-wide `GetIt.instance`, which belongs to the
/// host app.
final GetIt _eyzflowStreamingLocator = GetIt.asNewInstance();

typedef TizenDeviceNameReader = Future<String> Function();

/// Logs the connected Tizen device once for the lifetime of the app session.
final class TizenDeviceDiagnostics {
  TizenDeviceDiagnostics({TizenDeviceNameReader? readDeviceName})
    : _readDeviceName = readDeviceName ?? _readPlatformDeviceName;

  final TizenDeviceNameReader _readDeviceName;
  Future<void>? _loggedDevice;

  /// Starts the cached device lookup and returns the same future thereafter.
  Future<void> logDeviceOnce() => _loggedDevice ??= _logDevice();

  Future<void> _logDevice() async {
    try {
      logPlayback('device: ${await _readDeviceName()}');
    } on Object catch (error) {
      logPlayback('device lookup unavailable', error: error);
    }
  }

  /// Model plus platform version: the Tizen version decides which Widevine CDM
  /// the set carries, which decides which encryption schemes it can play.
  static Future<String> _readPlatformDeviceName() async {
    final TizenDeviceInfo info = await DeviceInfoPluginTizen().tizenInfo;
    return '${info.modelName ?? 'unknown model'} (Tizen '
        '${info.platformVersion ?? '?'}, build ${info.buildString ?? '?'})';
  }
}

/// Registers the app-session Tizen diagnostics service in the shared locator.
void setupTizenDeviceDiagnostics({TizenDeviceDiagnostics? diagnostics}) {
  if (_eyzflowStreamingLocator.isRegistered<TizenDeviceDiagnostics>()) {
    _eyzflowStreamingLocator.unregister<TizenDeviceDiagnostics>();
  }
  _eyzflowStreamingLocator.registerLazySingleton<TizenDeviceDiagnostics>(
    () => diagnostics ?? TizenDeviceDiagnostics(),
  );
}

/// Retrieves the diagnostics service registered during application bootstrap.
TizenDeviceDiagnostics getTizenDeviceDiagnostics() =>
    _eyzflowStreamingLocator<TizenDeviceDiagnostics>();

/// Retrieves diagnostics when application bootstrap has registered them.
TizenDeviceDiagnostics? getTizenDeviceDiagnosticsOrNull() =>
    _eyzflowStreamingLocator.isRegistered<TizenDeviceDiagnostics>()
    ? getTizenDeviceDiagnostics()
    : null;

/// Clears the registered Tizen diagnostics service.
///
/// Mainly useful for tests that repeatedly initialize this package-owned
/// locator.
void resetTizenDeviceDiagnostics() {
  if (_eyzflowStreamingLocator.isRegistered<TizenDeviceDiagnostics>()) {
    _eyzflowStreamingLocator.unregister<TizenDeviceDiagnostics>();
  }
}
