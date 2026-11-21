import 'dart:math';

/// Keeps a stable id for this device, sent with playback sessions and DRM
/// licences so the plan's device limit counts the device once.
// A named extension point the host implements (keychain, its own storage).
// ignore: one_member_abstracts
abstract interface class DeviceIdStore {
  /// The stored id, created and stored on first use.
  Future<String> read();
}

/// An id for the life of the process: for tests, and as the fallback when
/// storage is unavailable (the device then counts again after a restart).
final class MemoryDeviceIdStore implements DeviceIdStore {
  MemoryDeviceIdStore([String? id]) : _id = id;

  String? _id;

  @override
  Future<String> read() async => _id ??= newUuidV4();
}

/// A random (version 4) UUID.
String newUuidV4([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
