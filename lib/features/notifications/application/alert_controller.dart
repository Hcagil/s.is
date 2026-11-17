import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/alert_settings.dart';

/// The phone-only store of the defaults and the chats' own choices.
final alertStoreProvider = Provider<AlertStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// The phone's notification-sound chooser (Android only).
final tonePickerProvider = Provider<TonePicker>(
  (_) => throw UnimplementedError('override in main'),
);

/// The account-side copy of the settings; null = phone only (tests, signed out). main.dart overrides it.
final alertRemoteProvider = Provider<AlertRemote?>((_) => null);

/// The member's global sound and vibration settings, and the chats that
/// differ from them.
final class AlertPrefs {
  const AlertPrefs({required this.defaults, required this.chats});

  final AlertDefaults defaults;
  final Map<String, ChatAlert> chats;

  /// The chat's own choices; all Default when it has none.
  ChatAlert chat(String conversationId) =>
      chats[conversationId] ?? const ChatAlert();
}

/// Phone-only, so not tied to the signed-in account.
final alertPrefsProvider = AsyncNotifierProvider<AlertController, AlertPrefs>(
  AlertController.new,
);

class AlertController extends AsyncNotifier<AlertPrefs> {
  @override
  Future<AlertPrefs> build() async {
    ref.watch(currentUserIdProvider); // a switch of account loads that account's copy
    final store = ref.read(alertStoreProvider);
    final defaults = await store.loadDefaults();
    final chats = await store.loadChats();
    final local = AlertPrefs(defaults: defaults, chats: chats);

    final remote = ref.read(alertRemoteProvider);
    if (remote == null) return local;

    final loaded = await remote.load();
    if (loaded case Ok(:final value)) {
      final r = value;
      if (r.sound == null && r.vibration == null && r.chats.isEmpty) {
        // The account has nothing saved yet: upload what the phone has.
        await remote.saveDefaults(
          sound: defaults.sound,
          vibration: defaults.vibration,
        );
        for (final e in chats.entries) {
          await remote.saveChat(e.key, e.value);
        }
        return local;
      }

      // The account wins.
      final newDefaults = defaults.copyWith(
        sound: r.sound ?? defaults.sound,
        vibration: r.vibration ?? defaults.vibration,
      );
      if (newDefaults != defaults) {
        await store.saveDefaults(newDefaults);
      }
      for (final id in r.chats.keys) {
        await store.saveChat(id, r.chats[id]!);
      }
      for (final id in chats.keys) {
        if (!r.chats.containsKey(id)) {
          await store.saveChat(id, const ChatAlert());
        }
      }
      return AlertPrefs(defaults: newDefaults, chats: r.chats);
    }

    // The account could not be read: keep the phone's values.
    return local;
  }

  /// Saves new global settings.
  Future<Result<void>> setDefaults(AlertDefaults next) async {
    if (state.value == null) return const Ok(null);
    final remote = ref.read(alertRemoteProvider);
    if (remote != null) {
      final r = await remote.saveDefaults(
        sound: next.sound,
        vibration: next.vibration,
      );
      if (r case Err()) return r;
    }
    await ref.read(alertStoreProvider).saveDefaults(next);
    final current = state.value;
    if (ref.mounted && current != null) {
      state = AsyncData(AlertPrefs(defaults: next, chats: current.chats));
    }
    return const Ok(null);
  }

  /// Saves one chat's choices; all Default removes its entry.
  Future<Result<void>> setChat(String conversationId, ChatAlert next) async {
    if (state.value == null) return const Ok(null);
    final remote = ref.read(alertRemoteProvider);
    if (remote != null) {
      final r = await remote.saveChat(conversationId, next);
      if (r case Err()) return r;
    }
    await ref.read(alertStoreProvider).saveChat(conversationId, next);
    final current = state.value;
    if (ref.mounted && current != null) {
      state = AsyncData(
        AlertPrefs(
          defaults: current.defaults,
          chats: {
            for (final e in current.chats.entries)
              if (e.key != conversationId) e.key: e.value,
            if (!next.isDefault) conversationId: next,
          },
        ),
      );
    }
    return const Ok(null);
  }

  /// Opens the phone's tone chooser and saves what the member picks.
  Future<void> pickTone() async {
    final current = state.value;
    if (current == null) return;
    final picked = await ref
        .read(tonePickerProvider)
        .pick(current.defaults.tone);
    final latest = state.value;
    if (picked == null || latest == null) return;
    await setDefaults(
      latest.defaults.withTone(
        picked.tone,
        picked.tone == null ? null : picked.name,
      ),
    );
  }
}
