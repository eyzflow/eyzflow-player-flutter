import 'dart:io';

/// `Platform.operatingSystem`: `android`, `ios`, `tizen`, or `linux` on a
/// Samsung TV (flutter-tizen reports it so; the player routes it the
/// same way).
String? currentOperatingSystem() => Platform.operatingSystem;
