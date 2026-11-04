import '../../chat/data/store/store_key.dart';
import '../../chat/data/store/store_location.dart';
import '../../crypto/data/olm_peek.dart';
import '../../crypto/data/pickle_key.dart';
import '../domain/reaction_push.dart';

/// Opens a private chat's reaction push on the main isolate with the phone's own store and Olm keys, in memory only (peekReaction writes nothing). [keychainGroup] is the iPhone keychain group of the keys (null elsewhere).
Future<OpenedReaction?> Function(ReactionPush push) reactionOpener(
  String? keychainGroup,
) => (push) async {
  final ciphertext = push.ciphertext;
  final olmType = push.olmType;
  if (ciphertext == null || olmType == null) return null;

  final key = await StoreKey.inGroup(keychainGroup).read();
  final pickle = await PickleKey.inGroup(keychainGroup).read();
  if (key == null || pickle == null) return null;

  final r = await peekReaction(
    storePath: (await storeFile()).path,
    storeKeyHex: key,
    pickleKey: pickle,
    ownerId: push.userId,
    conversationId: push.conversationId,
    messageId: push.messageId,
    reactorId: push.reactorId,
    ciphertext: ciphertext,
    olmType: olmType,
  );
  return r == null ? null : (emoji: r.emoji, quote: r.quote);
};
