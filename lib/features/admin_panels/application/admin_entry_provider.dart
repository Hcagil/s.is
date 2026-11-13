import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import 'admin_panels_controller.dart';

/// True only when the server says this account is the owner (the Settings row shows only then).
final adminEntryProvider = FutureProvider.autoDispose<bool>((ref) async {
  final session = ref.watch(sessionControllerProvider).value;
  if (session is! Allowed) return false;

  final r = await ref.read(adminPanelsRepositoryProvider).status();
  return switch (r) {
    Ok(:final value) => value != null,
    Err() => false,
  };
});
