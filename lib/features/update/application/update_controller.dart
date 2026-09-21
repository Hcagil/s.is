import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
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
    final repo = ref.read(updateRepositoryProvider);
    final installed = await repo.installedBuild();
    // A failed policy fetch never blocks anyone: treat the minimum as 0.
    final min = switch (await repo.minSupportedBuild()) {
      Ok(:final value) => value,
      Err() => 0,
    };
    if (installed < min) {
      return UpdateRequired(installed: installed, minimum: min);
    }
    return switch (await repo.availablePlayBuild()) {
      Ok(value: final v?) when v > installed => UpdateAvailableFlexible(v),
      _ => const UpdateIdle(),
    };
  }

  Future<void> download() async {
    state = const AsyncData(UpdateDownloading());
    await ref.read(updateRepositoryProvider).startFlexibleUpdate();
    state = const AsyncData(UpdateReadyToInstall());
  }

  Future<void> install() =>
      ref.read(updateRepositoryProvider).completeFlexibleUpdate();

  void dismiss() => state = const AsyncData(UpdateIdle());

  Future<void> updateNow() =>
      ref.read(updateRepositoryProvider).startImmediateUpdate();
}
