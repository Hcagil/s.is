import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';

/// The chats ticked in the list (long-press, then taps). Empty = no selection.
final chatSelectionProvider = NotifierProvider<ChatSelection, Set<String>>(
  ChatSelection.new,
);

class ChatSelection extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentUserIdProvider);
    return const {};
  }

  void toggle(String id) {
    state = state.contains(id) ? (Set.of(state)..remove(id)) : {...state, id};
  }

  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}
