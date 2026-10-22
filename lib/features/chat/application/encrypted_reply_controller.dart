import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';
import '../domain/encrypted_reply.dart';
import '../domain/message.dart' show maxMessageLength;
import 'chat_drafts.dart';

/// The door a notification Reply reaches the app through (set in main). Until
/// then nothing arrives, so a widget tree built without the host (tests) works.
final encryptedReplyIntakeProvider = Provider<EncryptedReplyIntake>(
  (_) => const _NoEncryptedReplyIntake(),
);

/// A door nobody replies through.
class _NoEncryptedReplyIntake implements EncryptedReplyIntake {
  const _NoEncryptedReplyIntake();

  @override
  Future<List<PendingReply>> take() async => const [];

  @override
  Stream<void> get arrivals => const Stream<void>.empty();
}

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Held from the app start (sis_app.dart): sends the Replies typed into
/// private-chat notifications through the normal send queue, which locks the
/// text on this phone (and never sends it plain when locking fails). A reply
/// for another member than the signed-in one is dropped; with nobody signed in
/// it waits in the host.
final encryptedReplySenderProvider = Provider<void>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  final intake = ref.read(encryptedReplyIntakeProvider);

  Future<void> fetch() async {
    if (userId == null) return;
    final replies = await intake.take();
    if (!ref.mounted) return;
    for (final r in replies) {
      if (r.userId != userId) continue;
      if (!_uuid.hasMatch(r.id) || r.text.length > maxMessageLength) continue;
      ref
          .read(sendQueueProvider.notifier)
          .enqueue(r.conversationId, body: r.text, id: r.id);
    }
  }

  final sub = intake.arrivals.listen((_) => unawaited(fetch()));
  ref.onDispose(sub.cancel);
  unawaited(fetch());
});
