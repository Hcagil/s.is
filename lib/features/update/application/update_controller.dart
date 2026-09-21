import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/update_repository.dart';
import '../domain/update_state.dart';

final updateRepositoryProvider = Provider<UpdateRepository>(
  (_) => throw UnimplementedError('override in main'),
);

final updateControllerProvider =
    AsyncNotifierProvider<UpdateController, UpdateState>(UpdateController.new);

/// Decides whether the app is blocked, may offer an update, or is idle.
class UpdateController extends AsyncNotifier<UpdateState> {
  @override
  Future<UpdateState> build() async {
    // The policy row is readable only by an active member. Rebuild only when
    // that flips, not on every session transition (a dismissed banner stays
    // dismissed; the blocking screen never flickers through loading).
    final allowed = ref.watch(
      sessionControllerProvider.select((s) => s.value is Allowed),
    );
    final repo = ref.read(updateRepositoryProvider);
    final installed = await repo.installedBuild();
    if (allowed) {
      // A failed policy fetch never blocks anyone: treat the minimum as 0.
      final min = switch (await repo.minSupportedBuild()) {
        Ok(:final value) => value,
        Err() => 0,
      };
      if (installed < min) {
        return UpdateRequired(installed: installed, minimum: min);
      }
    }
    return switch (await repo.availablePlayBuild()) {
      Ok(value: final v?) when v > installed => UpdateAvailableFlexible(v),
      _ => const UpdateIdle(),
    };
  }

  Future<void> download() async {
    final current = state.value;
    state = const AsyncData(UpdateDownloading());
    try {
      await ref.read(updateRepositoryProvider).startFlexibleUpdate();
      if (!ref.mounted) return;
      state = const AsyncData(UpdateReadyToInstall());
    } catch (_) {
      // Declined or unavailable: return to the offer, never stay "downloading".
      if (!ref.mounted) return;
      state = AsyncData(
        current is UpdateAvailableFlexible ? current : const UpdateIdle(),
      );
    }
  }

  Future<void> install() async {
    try {
      await ref.read(updateRepositoryProvider).completeFlexibleUpdate();
    } catch (_) {
      if (!ref.mounted) return;
      state = const AsyncData(UpdateIdle());
    }
  }

  void dismiss() => state = const AsyncData(UpdateIdle());

  Future<void> updateNow() async {
    final repo = ref.read(updateRepositoryProvider);
    try {
      await repo.startImmediateUpdate();
    } catch (_) {
      // Play cannot run an immediate update here: send the user to the listing.
      await repo.openStoreListing();
    }
  }
}
