import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message.dart';
import '../domain/pending_push_messages.dart';

/// Where the lines a plain push saved while the app was closed are read
/// from. main.dart overrides it with the phone's real source; the default
/// (tests) has none and never throws.
final pendingPushMessagesProvider = Provider<PendingPushMessages>(
  (_) => const _NoPendingPushMessages(),
);

final class _NoPendingPushMessages implements PendingPushMessages {
  const _NoPendingPushMessages();

  @override
  Future<List<Message>> pendingPushMessages(String ownerId) async => const [];
}
