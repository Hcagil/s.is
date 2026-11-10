import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/features/device/application/device_report_controller.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/device/domain/device_reporter.dart';

class _Spy implements DeviceReporter {
  int calls = 0;
  Object? error;
  @override
  Future<void> report() async {
    calls++;
    if (error != null) throw error!;
  }
}

class _Me extends CurrentUserId {
  _Me(this.id);
  final String? id;
  @override
  String? build() => id;
}

class _MeWithSet extends CurrentUserId {
  _MeWithSet(this.id);
  String? id;
  @override
  String? build() => id;
  void set(String? v) => state = v;
}

void main() {
  test('deviceReportProvider does not call report when signed out', () {
    final spy = _Spy();
    final container = ProviderContainer(
      overrides: [
        deviceReporterProvider.overrideWithValue(spy),
        currentUserIdProvider.overrideWith(() => _Me(null)),
      ],
    );
    addTearDown(container.dispose);

    container.read(deviceReportProvider);
    expect(spy.calls, 0);
  });

  test('deviceReportProvider calls report once when signed in', () async {
    final spy = _Spy();
    final container = ProviderContainer(
      overrides: [
        deviceReporterProvider.overrideWithValue(spy),
        currentUserIdProvider.overrideWith(() => _Me('user-1')),
      ],
    );
    addTearDown(container.dispose);

    container.read(deviceReportProvider);
    await Future<void>.delayed(Duration.zero);
    expect(spy.calls, 1);
  });

  test(
    'deviceReportProvider does not call report again on subsequent reads',
    () async {
      final spy = _Spy();
      final container = ProviderContainer(
        overrides: [
          deviceReporterProvider.overrideWithValue(spy),
          currentUserIdProvider.overrideWith(() => _Me('user-1')),
        ],
      );
      addTearDown(container.dispose);

      // Keep the container alive and listen to the provider
      container.listen(deviceReportProvider, (_, _) {});
      container.read(deviceReportProvider);
      await Future<void>.delayed(Duration.zero);
      expect(spy.calls, 1);

      // Read again and pump event queue
      container.read(deviceReportProvider);
      await Future<void>.delayed(Duration.zero);
      expect(spy.calls, 1);
    },
  );

  test('deviceReportProvider calls report once after user signs in', () async {
    final spy = _Spy();
    final container = ProviderContainer(
      overrides: [
        deviceReporterProvider.overrideWithValue(spy),
        currentUserIdProvider.overrideWith(() => _MeWithSet(null)),
      ],
    );
    addTearDown(container.dispose);

    container.listen(deviceReportProvider, (_, _) {}); // as SisApp mounts it
    expect(spy.calls, 0);

    // Sign in
    (container.read(currentUserIdProvider.notifier) as _MeWithSet).set(
      'user-2',
    );
    await Future<void>.delayed(Duration.zero);
    expect(spy.calls, 1);
  });
}
