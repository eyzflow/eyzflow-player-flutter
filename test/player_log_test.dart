import 'package:eyzflow_player/src/player/player_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug stream diagnostics preserve the complete URL', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    const url =
        'https://cdn.example/videos/film-123/master.m3u8?token=abc&x=1#part';
    if (kDebugMode) logPlayback('source.prepare url=$url');
    expect(lines.single, '[eyzflow-streaming] source.prepare url=$url');
  });
  test('errors and stack traces cannot disclose credentials', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    logPlayback(
      'playback failed',
      error: StateError('SECRET'),
      stackTrace: StackTrace.fromString('SECRET'),
    );
    expect(lines.join(), contains('[eyzflow-streaming]'));
    expect(lines.join(), isNot(contains('SECRET')));
  });
}
