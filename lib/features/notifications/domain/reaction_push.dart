final _uuidShape = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// A reaction push received while the app is open. [ciphertext] and [olmType] are set only for a private chat (the emoji and quote are then sealed in it).
typedef ReactionPush = ({
  String userId,
  String conversationId,
  String messageId,
  String reactorId,
  String? emoji,
  String? quote,
  String? quoteKind,
  String? ciphertext,
  int? olmType,
});

/// A reaction opened on this phone.
typedef OpenedReaction = ({String emoji, String? quote});

/// What the top card needs to word a reaction. A null [emoji] means the generic text; [kind] is photo, video, sticker, voice, file or null.
typedef ReactionLine = ({String? emoji, String? quote, String? kind});

/// The reaction push in [data], or null when it is not one or any id is not UUID-shaped.
ReactionPush? parseReactionPush(Map<String, dynamic> data) {
  if (data['kind'] != 'reaction') return null;

  String? text(String key) {
    final v = data[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  String? id(String key) {
    final v = text(key);
    return v != null && _uuidShape.hasMatch(v) ? v : null;
  }

  final userId = id('user_id');
  final conversationId = id('conversation_id');
  final messageId = id('message_id');
  final reactorId = id('reactor_id');

  if (userId == null ||
      conversationId == null ||
      messageId == null ||
      reactorId == null) {
    return null;
  }

  final ciphertext = text('ct');
  final ot = int.tryParse(text('ot') ?? '');
  final olmType = ot == 0 || ot == 1 ? ot : null;

  if (ciphertext != null && olmType == null) return null;

  return (
    userId: userId,
    conversationId: conversationId,
    messageId: messageId,
    reactorId: reactorId,
    emoji: text('e'),
    quote: text('q'),
    quoteKind: text('qk'),
    ciphertext: ciphertext,
    olmType: olmType,
  );
}
