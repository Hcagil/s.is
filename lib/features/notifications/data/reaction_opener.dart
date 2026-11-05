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

  final key = await StoreKey.inGroup(keychainGroup).read();
  final pickle = await PickleKey.inGroup(keychainGroup).read();
  if (key == null || pickle == null) return null;

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
