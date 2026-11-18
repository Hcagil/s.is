import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';

/// Whether the chat list shows groups only (false means All).
final chatListGroupsOnlyProvider = NotifierProvider<ChatListGroupsOnly, bool>(
  ChatListGroupsOnly.new,
);

/// Holds the chat list groups-only filter and resets to All when the account changes.
class ChatListGroupsOnly extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(currentUserIdProvider);
    return false;
  }

  void set(bool groupsOnly) {
    state = groupsOnly;
  }
}
