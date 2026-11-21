import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/src/player/tizen_device_diagnostics.dart';

void main() {
  setUp(resetTizenDeviceDiagnostics);

  tearDown(resetTizenDeviceDiagnostics);

  test(
    'registered diagnostics resolve once and read the device once',
    () async {
      var reads = 0;
      final diagnostics = TizenDeviceDiagnostics(
        readDeviceName: () async {
          reads++;
          return 'Test TV';
        },
      );

      setupTizenDeviceDiagnostics(diagnostics: diagnostics);

      final resolved = getTizenDeviceDiagnostics();
      expect(resolved, same(diagnostics));

      await Future.wait([resolved.logDeviceOnce(), resolved.logDeviceOnce()]);

      expect(reads, 1);
    },
  );

  test('returns no diagnostics before application bootstrap', () {
    expect(getTizenDeviceDiagnosticsOrNull(), isNull);
  });
}
