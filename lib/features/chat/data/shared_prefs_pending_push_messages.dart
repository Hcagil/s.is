import 'dart:convert';
import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import '../../notifications/domain/notification_inbox.dart';
import '../domain/message.dart';
import '../domain/pending_push_messages.dart';

final class SharedPrefsPendingPushMessages implements PendingPushMessages {
  const SharedPrefsPendingPushMessages();

  @override
  Future<List<Message>> pendingPushMessages(String ownerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // What the background isolate wrote must be seen here.
      await prefs.reload();
      final raw = prefs.getString('sis.push_inbox.$ownerId');
      if (raw == null) return const [];
      final chats = [
        for (final e in jsonDecode(raw) as List)
          InboxChat.fromJson(e as Map<String, Object?>),
      ];
      final out = <Message>[];
      for (final chat in chats) {
        for (final line in chat.lines) {
          final id = line.id;
          final senderId = line.senderId;
          if (id == null || id.startsWith('r:')) continue;
          if (senderId == null || senderId.isEmpty) continue;
          out.add(
            Message(
              id: id,
              conversationId: chat.conversationId,
              senderId: senderId,
              body: line.text,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                line.at,
                isUtc: true,
              ),
            ),
          );
        }
      }
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } catch (e) {
      log(
        'Reading pending push lines failed: ${e.runtimeType}',
        name: 'sis.push',
      );
      return const [];
    }
  }
}
