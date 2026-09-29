import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/alert_settings.dart';

/// The phone-only store of the defaults and the chats' own choices.
final alertStoreProvider = Provider<AlertStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// The phone's notification-sound chooser (Android only).
final tonePickerProvider = Provider<TonePicker>(
  (_) => throw UnimplementedError('override in main'),
);

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
    final store = ref.read(alertStoreProvider);
    return AlertPrefs(
      defaults: await store.loadDefaults(),
      chats: await store.loadChats(),
    );
  }

  /// Saves new global settings.
  Future<void> setDefaults(AlertDefaults next) async {
    if (state.value == null) return;
    await ref.read(alertStoreProvider).saveDefaults(next);
    final current = state.value;
    if (ref.mounted && current != null) {
      state = AsyncData(AlertPrefs(defaults: next, chats: current.chats));
    }
  }

  /// Saves one chat's choices; all Default removes its entry.
  Future<void> setChat(String conversationId, ChatAlert next) async {
    if (state.value == null) return;
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
