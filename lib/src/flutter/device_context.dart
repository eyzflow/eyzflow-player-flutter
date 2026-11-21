import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api.dart';
import '../core/device_id.dart';
import 'platform_os.dart';

/// The platform the player runs on, as sessions and beats name it. Null where
/// the package shows no player (web, desktop).
PlayerPlatform? resolvePlayerPlatform({required bool isTv, String? os}) {
  return switch (os ?? currentOperatingSystem()) {
    'android' => isTv ? PlayerPlatform.androidTv : PlayerPlatform.android,
    'ios' => PlayerPlatform.ios,
    'tizen' || 'linux' => PlayerPlatform.tizen,
    _ => null,
  };
}

/// The app's package name or bundle id, or null where the platform cannot
/// say (a Tizen app without the plugin's Tizen implementation).
Future<String?> readAppId() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.packageName.isEmpty ? null : info.packageName;
  } on Object catch (error) {
    debugPrint('[eyzflow-player] app id unavailable: $error');
    return null;
  }
}

/// The device id in shared preferences under `eyzflow.deviceId` (the web
/// player's local-storage key). Falls back to an id for the process when the
/// plugin is missing (Tizen without `shared_preferences_tizen`).
final class SharedPreferencesDeviceIdStore implements DeviceIdStore {
  SharedPreferencesDeviceIdStore({this.key = 'eyzflow.deviceId'});

  final String key;
  static String? _memory;

  @override
  Future<String> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(key);
      if (stored != null && stored.isNotEmpty) return stored;
      final id = newUuidV4();
      await prefs.setString(key, id);
      return id;
    } on MissingPluginException catch (error) {
      debugPrint('[eyzflow-player] device id not stored: $error');
      return _memory ??= newUuidV4();
    }
  }
}
