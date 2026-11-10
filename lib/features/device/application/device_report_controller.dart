import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';
import '../domain/device_reporter.dart';

/// Where device reports are sent to (Supabase in data/). Defaults to
/// nothing so a build without it still runs.
final deviceReporterProvider = Provider<DeviceReporter>(
  (_) => const _NoReporter(),
);

final class _NoReporter implements DeviceReporter {
  const _NoReporter();
  @override
  Future<void> report() async {}
}

/// Sends device info once per app start for whoever is signed in. A
/// failure is never shown.
final deviceReportProvider = NotifierProvider<DeviceReportController, void>(
  DeviceReportController.new,
);

class DeviceReportController extends Notifier<void> {
  @override
  void build() {
    final me = ref.watch(currentUserIdProvider);
    if (me == null) return;
    unawaited(ref.read(deviceReporterProvider).report());
  }
}
