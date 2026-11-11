import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/services/log_source.dart';
import 'package:arcadiaplus/src/services/service_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceDiagnostics.clear();
  });

  test(
    'failure before native initialization is visible in state and logs',
    () async {
      final state = AppStateProvider();
      addTearDown(state.dispose);
      expect(await state.startService(), isFalse);
      expect(state.isServiceRunning, isFalse);
      expect(state.serviceError, contains('Native core'));
      const logs = NativeLogSource();
      expect((await logs.read()).single, contains(state.serviceError!));
      await logs.clear();
      expect(ServiceDiagnostics.entries, isEmpty);
    },
  );

  test('startup diagnostics are bounded and single-line', () {
    for (var i = 0; i < 50; i++) {
      ServiceDiagnostics.failure('failure $i\nrollback');
    }
    expect(ServiceDiagnostics.entries, hasLength(32));
    expect(ServiceDiagnostics.entries.last, contains('failure 49 rollback'));
  });
}
