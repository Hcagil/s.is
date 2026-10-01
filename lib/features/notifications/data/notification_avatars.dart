import 'dart:typed_data';

import '../../chat/data/file_attachment_cache.dart';
import '../../chat/data/file_chat_list_snapshot_store.dart';

/// The pictures a notification shows, taken only from what the app already
/// keeps on the phone: the chat list snapshot (who each chat is) and the
/// avatar cache (their picture, saved when the chat list first showed it).
/// Never the network: the background isolate that draws a push has no session
/// and no time to wait for a download. A chat whose picture is not on the
/// phone simply has none.
final class NotificationAvatars {
  const NotificationAvatars._();

  /// For each of [conversationIds], the picture bytes of the other person (a
  /// 1:1 chat) or of the group, when both the snapshot of [owner]'s chat list
  /// and the cached picture are here. Never throws.
  static Future<Map<String, Uint8List>> forChats(
    String owner,
    Iterable<String> conversationIds,
  ) async {
    try {
      final list = await FileChatListSnapshotStore().load(owner);
      if (list == null) return {};
      final cache = FileAttachmentCache();
      final paths = {
        for (final c in list)
          c.id: c.isGroup ? c.avatarPath : c.other?.avatarPath,
      };
      final result = <String, Uint8List>{};
      for (final id in conversationIds) {
        final path = paths[id];
        if (path == null) continue;
        final bytes = await cache.read(path);
        if (bytes != null && bytes.isNotEmpty) result[id] = bytes;
      }
      return result;
    } catch (_) {
      return {};
    }
  }
}
