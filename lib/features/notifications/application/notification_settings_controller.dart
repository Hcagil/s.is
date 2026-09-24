import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/notification_settings.dart';

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>(
      (_) => throw UnimplementedError('override in main'),
    );

/// Riverpod 3 would otherwise retry a failed build forever and never settle
/// on an error the screen can show (see chat_controllers.dart).
Duration? _never(int retryCount, Object error) => null;

/// The signed-in member's own notification settings. Loaded only while a
/// page shows them; watches the account, so a switch loads the new one's.
final notificationSettingsProvider =
    AsyncNotifierProvider.autoDispose<
      NotificationSettingsController,
      NotificationSettings
    >(NotificationSettingsController.new, retry: _never);

class NotificationSettingsController
    extends AsyncNotifier<NotificationSettings> {
  @override
  Future<NotificationSettings> build() async {
    // The settings of whoever is signed in now; a switch loads the new ones.
    ref.watch(currentUserIdProvider);
    return switch (await ref
        .read(notificationSettingsRepositoryProvider)
        .load()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
  }

  /// Saves new settings. On failure the settings on screen are left as they
  /// were and the reason is returned for the screen to show.
  Future<Result<void>> save(NotificationSettings next) async {
    final result = await ref
        .read(notificationSettingsRepositoryProvider)
        .save(next);
    if (result case Ok() when ref.mounted) {
      state = AsyncData(next);
    }
    return result;
  }

  Future<void> retry() async => ref.invalidateSelf();
}

/// The signed-in member's own mutes. Loaded only while a page shows them;
/// watches the account, so a switch loads the new one's.
final mutesProvider =
    AsyncNotifierProvider.autoDispose<MutesController, List<Mute>>(
      MutesController.new,
      retry: _never,
    );

class MutesController extends AsyncNotifier<List<Mute>> {
  @override
  Future<List<Mute>> build() async {
    // The mutes of whoever is signed in now; a switch loads the new ones.
    ref.watch(currentUserIdProvider);
    return switch (await ref
        .read(notificationSettingsRepositoryProvider)
        .mutes()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
  }

  /// Mutes a conversation or person for the given length.
  Future<Result<void>> mute(
    MuteKind kind,
    String target,
    MuteLength length,
  ) async {
    final until = length.until(DateTime.now());
    final result = await ref
        .read(notificationSettingsRepositoryProvider)
        .mute(kind, target, until);
    if (result case Ok() when ref.mounted) {
      state = AsyncData([
        for (final m in state.value ?? const <Mute>[])
          if (m.kind != kind || m.target != target) m,
        Mute(kind: kind, target: target, until: until),
      ]);
    }
    return result;
  }

  /// Unmutes a conversation or person.
  Future<Result<void>> unmute(MuteKind kind, String target) async {
    final result = await ref
        .read(notificationSettingsRepositoryProvider)
        .unmute(kind, target);
    if (result case Ok() when ref.mounted) {
      state = AsyncData([
        for (final m in state.value ?? const <Mute>[])
          if (m.kind != kind || m.target != target) m,
      ]);
    }
    return result;
  }
}

/// The mute currently silencing [target], if any; an expired one counts as
/// none.
Mute? activeMute(List<Mute> mutes, MuteKind kind, String target, DateTime now) {
  for (final mute in mutes) {
    if (mute.kind == kind && mute.target == target && mute.activeAt(now)) {
      return mute;
    }
  }
  return null;
}
