// A SendQueueStore that outlives a ProviderContainer, as the on-phone store
// outlives an app kill. Written from the SendQueueStore contract
// (lib/features/chat/domain/send_queue_store.dart): load leaves out records
// whose file or video is gone from the phone; each call takes an async hop.
// Like the send_queue table it also holds the ciphertext of a queued text:
// written only onto a row that exists, kept while the row stays, gone with it.
import 'dart:io';

import 'package:sis/features/chat/domain/send_queue_store.dart';

class MemorySendQueueStore implements SendQueueStore, QueuedCiphertexts {
  /// What is saved, per member; a member with nothing saved has no entry.
  final saved = <String, List<QueuedRecord>>{};

  @override
  Future<List<QueuedRecord>> load(String userId) async {
    await Future<void>.value();
    return [
      for (final r in saved[userId] ?? const <QueuedRecord>[])
        if ((r.file == null || File(r.file!.path).existsSync()) &&
            (r.video == null || File(r.video!.path).existsSync()))
          r,
    ];
  }

  /// How long a save takes (on the test clock); zero: one async hop.
  Duration saveDelay = Duration.zero;

  @override
  Future<void> save(String userId, List<QueuedRecord> records) async {
    records = List.of(records);
    await (saveDelay == Duration.zero
        ? Future<void>.value()
        : Future<void>.delayed(saveDelay));
    final keep = {for (final r in records) r.id};
    cipher.removeWhere((k, _) => k.$1 == userId && !keep.contains(k.$2));
    if (records.isEmpty) {
      saved.remove(userId);
    } else {
      saved[userId] = List.of(records);
    }
  }

  @override
  Future<void> clear() async {
    await Future<void>.value();
    saved.clear();
    cipher.clear();
  }

  /// Ciphertexts on queue rows, by (member, queued id).
  final cipher = <(String, String), QueuedCiphertext>{};

  /// What the session engine does with a QueueTarget: writes the ciphertext
  /// onto the row in the same transaction, or nothing when no row exists.
  bool write(String userId, String id, String ciphertext, int olmType) {
    final held = saved[userId]?.any((r) => r.id == id) ?? false;
    if (held) cipher[(userId, id)] = QueuedCiphertext(ciphertext, olmType);
    return held;
  }

  @override
  Future<QueuedCiphertext?> ciphertextOf(String userId, String id) async {
    await Future<void>.value();
    return cipher[(userId, id)];
  }
}
