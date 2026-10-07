import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/chat_pin_repository.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/message.dart';

/// [ChatPinRepository] behaving like the server: the caller's pinned chats
/// with the 5-pin limit (re-pinning a pinned chat is fine), one pinned
/// message per chat, latency on every call, and a [hold] a test completes to
/// look at the optimistic state while the server has not answered.
class ChatPinFake implements ChatPinRepository {
  ChatPinFake({
    this.latency = const Duration(milliseconds: 40),
    Set<String>? pinned,
  }) : pinned = pinned ?? {};

  final Duration latency;

  /// The caller's pinned chats as the server holds them.
  final Set<String> pinned;

  /// Pinned message id per chat as the server holds it.
  final pinnedMessages = <String, String?>{};

  /// What [pinnedMessage] fetches, by message id; a missing id answers
  /// Ok(null) (deleted or unreadable).
  final messages = <String, Message>{};

  /// What [pinEvents] answers, per chat.
  final events = <String, List<GroupEvent>>{};

  /// Every call in order: `chat:<id>:<pinned>`, `message:<conv>:<msg|->`,
  /// `fetch:<conv>:<msg>`, `events:<conv>`, `who:<conv>:<allowed>`.
  final calls = <String>[];

  /// When set, the next write answers this instead of the server's own rule.
  Result<void>? writeResult;

  /// When set, [pinnedMessage] answers this.
  Result<Message?>? fetchResult;

  Completer<void>? hold;

  Future<void> _wait() async {
    await Future<void>.delayed(latency);
    if (hold != null) await hold!.future;
  }

  @override
  Future<Result<void>> setChatPinned(String conversationId, bool pinned) async {
    calls.add('chat:$conversationId:$pinned');
    await _wait();
    final forced = writeResult;
    if (forced != null) return forced;
    final held = this.pinned;
    if (pinned && !held.contains(conversationId) && held.length >= 5) {
      return const Err(PinLimitFailure());
    }
    pinned ? held.add(conversationId) : held.remove(conversationId);
    return const Ok(null);
  }

  @override
  Future<Result<void>> setPinnedMessage(
    String conversationId,
    String? messageId,
  ) async {
    calls.add('message:$conversationId:${messageId ?? '-'}');
    await _wait();
    final forced = writeResult;
    if (forced != null) return forced;
    pinnedMessages[conversationId] = messageId;
    return const Ok(null);
  }

  @override
  Future<Result<Message?>> pinnedMessage(
    String conversationId,
    String messageId,
  ) async {
    calls.add('fetch:$conversationId:$messageId');
    await _wait();
    return fetchResult ?? Ok(messages[messageId]);
  }

  @override
  Future<Result<List<GroupEvent>>> pinEvents(String conversationId) async {
    calls.add('events:$conversationId');
    await _wait();
    return Ok(events[conversationId] ?? const []);
  }

  @override
  Future<Result<void>> setMembersCanPin(
    String conversationId,
    bool allowed,
  ) async {
    calls.add('who:$conversationId:$allowed');
    await _wait();
    return writeResult ?? const Ok(null);
  }
}
