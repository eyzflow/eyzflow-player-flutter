import 'package:eyzflow_player/src/native/native_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Cast button over AVKit's controls (iOS): shown and hidden on the
/// player's view, put back on each new view, taps reported to Dart.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('eyzflow_player_native');
  const controllerChannel = MethodChannel(
    'eyzflow_player_native_controller_42',
  );
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  late NativeVideoPlayerController controller;

  Iterable<Object?> castCalls() => calls
      .where((c) => c.method == 'setCastButtonVisible')
      .map((c) => c.arguments);

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(plugin, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      controllerChannel,
      (call) async => null,
    );
    controller = NativeVideoPlayerController(id: 42, androidCastLabel: 'Cast');
  });
  tearDown(() async {
    await controller.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(plugin, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      controllerChannel,
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shown before the view exists, it goes on each new view', (
    tester,
  ) async {
    // testWidgets checks the override is reset by the end of the body.
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await controller.setCastButtonVisible(true);
    expect(castCalls(), isEmpty);

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    // Real async: the view's setup runs timers of its own.
    await tester.runAsync(() => controller.onPlatformViewCreated(7, context));
    expect(castCalls(), [
      {'viewId': 7, 'visible': true, 'label': 'Cast'},
    ]);

    await controller.setCastButtonVisible(false);
    expect(castCalls().last, {'viewId': 7, 'visible': false, 'label': 'Cast'});
    // The same state again sends nothing.
    await controller.setCastButtonVisible(false);
    expect(castCalls(), hasLength(2));
    await tester.runAsync(controller.dispose);
    debugDefaultTargetPlatformOverride = null;
  });

  test('a tap arrives with the position', () async {
    final taps = <Duration>[];
    final subscription = controller.castRequests.listen(taps.add);
    await Future<void>.delayed(Duration.zero);
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      controllerChannel.name,
      codec.encodeSuccessEnvelope({
        'event': 'castRequested',
        'positionMs': 61500,
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(taps, [const Duration(milliseconds: 61500)]);
    await subscription.cancel();
  });
}
