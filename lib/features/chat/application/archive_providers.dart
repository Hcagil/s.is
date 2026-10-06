import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/conversation.dart';
import 'chat_controllers.dart';

/// The chats the member archived, in the list's order (newest message first).
/// Read from the same stored list as everything else, so the Archived screen
/// opens at once from stored data.
final archivedChatsProvider = Provider<List<Conversation>>(
  (ref) => [
    for (final c
        in ref.watch(conversationListProvider).value ?? const <Conversation>[])
      if (c.archived) c,
  ],
);

/// How many archived chats have something unread: the small count on the
/// Archived chats row.
final archivedUnreadCountProvider = Provider<int>(
  (ref) => ref.watch(archivedChatsProvider).where((c) => c.unread > 0).length,
);
