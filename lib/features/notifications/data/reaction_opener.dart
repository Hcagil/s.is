import 'dart:isolate';

import '../../chat/data/store/store_key.dart';
import '../../chat/data/store/store_location.dart';
import '../../crypto/data/olm_peek.dart';
import '../../crypto/data/pickle_key.dart';
import '../domain/reaction_push.dart';

/// Opens a private chat's reaction push in a background isolate (keys read on the main one) with the phone's own store and Olm keys, in memory only (peekReaction writes nothing). [keychainGroup] is the iPhone keychain group of the keys (null elsewhere).
Future<OpenedReaction?> Function(ReactionPush push) reactionOpener(
  String? keychainGroup,
) => (push) async {
  final ciphertext = push.ciphertext;
  final olmType = push.olmType;
  if (ciphertext == null || olmType == null) return null;

  final keys = await _readKeys(keychainGroup);
  if (keys == null) return null;
  final key = keys.key;
  final pickle = keys.pickle;

  final path = (await storeFile()).path;
  final userId = push.userId;
  final conversationId = push.conversationId;
  final messageId = push.messageId;
  final reactorId = push.reactorId;

  // SQLite is synchronous: keep it off the main isolate (RustLib inits itself in the new isolate).
  return Isolate.run(
    () => _peek(
      path,
      key,
      pickle,
      userId,
      conversationId,
      messageId,
      reactorId,
      ciphertext,
      olmType,
    ),
  );
};

/// The two keys, or null when secure storage cannot be read now or a key is absent. Never throws, never deletes.
Future<({String key, List<int> pickle})?> _readKeys(String? group) async {
  try {
    final key = await StoreKey.inGroup(group).read();
    final pickle = await PickleKey.inGroup(group).read();
    if (key == null || pickle == null) return null;
    return (key: key, pickle: pickle);
  } catch (_) {
    // Secure storage not ready: cannot open now (plain fallback notification); nothing is deleted.
    return null;
  }
}

Future<OpenedReaction?> _peek(
  String storePath,
  String storeKeyHex,
  List<int> pickleKey,
  String ownerId,
  String conversationId,
  String messageId,
  String reactorId,
  String ciphertext,
  int olmType,
) async {
  final r = await peekReaction(
    storePath: storePath,
    storeKeyHex: storeKeyHex,
    pickleKey: pickleKey,
    ownerId: ownerId,
    conversationId: conversationId,
    messageId: messageId,
    reactorId: reactorId,
    ciphertext: ciphertext,
    olmType: olmType,
  );
  return r == null ? null : (emoji: r.emoji, quote: r.quote);
}
