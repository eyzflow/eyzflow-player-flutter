import 'package:eyzflow_player/src/native/native_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('eyzflow_player_native');
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  late NativeVideoPlayerController controller;
  Future<void> emit(String name, [Map<String, Object> data = const {}]) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'eyzflow_player_native_controller_42',
      codec.encodeSuccessEnvelope({'event': name, ...data}),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(plugin, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'getPlaybackIntentRevision') return 7;
      if (call.method == 'getPictureInPictureStatus') return false;
      if (call.method == 'enterPictureInPicture') return true;
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('eyzflow_player_native_controller_42'),
      (call) async => null,
    );
    controller = NativeVideoPlayerController(id: 42);
  });
  tearDown(() async {
    await controller.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(plugin, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('eyzflow_player_native_controller_42'),
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });
  test('nativePipEventsDriveState', () async {
    await Future<void>.delayed(Duration.zero);
    await emit('pipStart');
    expect(controller.isPipEnabled, isTrue);
    await emit('pipStop');
    expect(controller.isPipEnabled, isFalse);
  });
  test('closedEventContainsFinalPosition', () async {
    final events = <AndroidPlaybackEvent>[];
    final subscription = controller.androidPlaybackEvents.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    await emit('playbackClosed', {
      'reason': 'pipDismissed',
      'positionMs': 23000,
    });
    expect(events.single.position, const Duration(seconds: 23));
    expect(events.single.closed, isTrue);
    expect(events.single.reason, 'pipDismissed');
    await subscription.cancel();
  });
  test('disposedControllerIgnoresLateEvent', () async {
    final events = <AndroidPlaybackEvent>[];
    controller.androidPlaybackEvents.listen(events.add);
    await Future<void>.delayed(Duration.zero);
    await controller.dispose();
    await emit('playbackClosed', {
      'reason': 'pipDismissed',
      'positionMs': 23000,
    });
    expect(events, isEmpty);
    expect(
      calls.where((c) => c.method == 'teardownControllerEventChannel'),
      hasLength(1),
    );
  });
  test('returnDoesNotSendPlay', () async {
    await Future<void>.delayed(Duration.zero);
    await emit('playbackPaused', {'reason': 'hidden', 'positionMs': 1000});
    await emit('pipStop');
    await controller.setAndroidPlayerRouteActive(true);
    expect(calls.where((c) => c.method == 'play'), isEmpty);
  });
  test('pipDoesNotSuppressSelectedCaptions', () async {
    await Future<void>.delayed(Duration.zero);
    await emit('pipStart');
    await emit('pipStop');
    expect(
      calls.where((c) => c.method == 'setSubtitlesSuppressedForPip'),
      isEmpty,
    );
  });
  test('routeInactiveIsControllerScoped', () async {
    await Future<void>.delayed(Duration.zero);
    await controller.setAndroidPlayerRouteActive(false);
    final call = calls.singleWhere((c) => c.method == 'setPlayerRouteActive');
    expect(call.arguments, {'controllerId': 42, 'active': false});
  });
  test('startupIntentAndManualPipUseControllerChannel', () async {
    await Future<void>.delayed(Duration.zero);
    final revision = await controller.getAndroidPlaybackIntentRevision();
    expect(revision, 7);
    await controller.playIfAndroidIntentUnchanged(revision);
    expect(
      calls.singleWhere((c) => c.method == 'playIfIntentUnchanged').arguments,
      {'controllerId': 42, 'revision': 7},
    );
    expect(await controller.enterPictureInPicture(), isTrue);
    expect(
      calls.singleWhere((c) => c.method == 'enterPictureInPicture').arguments,
      {'controllerId': 42},
    );
  });
}
