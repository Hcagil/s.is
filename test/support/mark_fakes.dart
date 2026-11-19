import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/chat_mark_repository.dart';

/// The server side of "mark as unread", derived from the interface: records
/// every call, answers Ok unless told to refuse, and can answer late (a slow
/// phone) so a test sees what the list shows while the call is in flight.
class MarkFake implements ChatMarkRepository {
  /// Every conversation id markChatUnread was called for, in order.
  final calls = <String>[];

  /// What the next calls answer; Ok unless forced.
  Result<void> result = const Ok(null);

  Completer<void>? _hold;

  /// Calls stay in flight until [release].
  void hold() => _hold = Completer<void>();
  void release() => _hold?.complete();

  @override
  Future<Result<void>> markChatUnread(String conversationId) async {
    calls.add(conversationId);
    if (_hold case final h?) await h.future;
    return result;
  }
}
