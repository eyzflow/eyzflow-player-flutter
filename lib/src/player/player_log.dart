import 'package:flutter/foundation.dart';

/// Device-visible diagnostics. Messages must contain only safe fields.
/// Raw SDK errors and stack traces are deliberately never serialized.
void logPlayback(String message, {Object? error, StackTrace? stackTrace}) {
  if (error != null) {
    debugPrint('[eyzflow-streaming] $message error=operation_failed');
  } else if (kDebugMode) {
    debugPrint('[eyzflow-streaming] $message');
  }
}
