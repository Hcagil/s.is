import 'dart:convert';

/// The exact UTF-8 length of every reaction envelope. The envelope without the emoji is 115 bytes and an emoji is at most [maxReactionEmojiBytes], so 192 always fits; every envelope is padded to it, so the ciphertext length (the cipher rounds to 16-byte blocks) reveals nothing about the emoji.
const int reactionEnvelopeBytes = 192;

/// The longest emoji (UTF-8 bytes) a reaction may carry; the server refuses more, and the phone refuses it before locking.
const int maxReactionEmojiBytes = 64;

/// The JSON text that is locked for a reaction: `{"v":1,"k":"r","i":messageId,"u":userId,"e":emoji,"p":padding}`. The padding is spaces inside the string `p`, so the UTF-8 length is exactly [reactionEnvelopeBytes] (an emoji over [maxReactionEmojiBytes] bytes is refused by the caller; this function would then send it unpadded). A reaction envelope has no `t`, so decodeEnvelope refuses it.
String encodeReactionEnvelope({
  required String messageId,
  required String userId,
  required String emoji,
}) {
  final Map<String, Object?> map = {
    'v': 1,
    'k': 'r',
    'i': messageId,
    'u': userId,
    'e': emoji,
    'p': '',
  };
  final String json = jsonEncode(map);
  final int len = utf8.encode(json).length;
  if (len >= reactionEnvelopeBytes) return json;
  map['p'] = ' ' * (reactionEnvelopeBytes - len);
  return jsonEncode(map);
}

/// Reads the JSON text [json] that [encodeReactionEnvelope] made for the reaction of [userId] to [messageId]. Null (never a throw) when it is not valid JSON, not an object, `v` is not 1, `k` is not 'r' (a message envelope has no `k`), `i` is not exactly [messageId], `u` is not exactly [userId] (a copy of another reaction replayed into this row), or `e` is not a non-empty string or is longer than [maxReactionEmojiBytes] UTF-8 bytes.
String? decodeReactionEnvelope(
  String json, {
  required String messageId,
  required String userId,
}) {
  final Object? map;
  try {
    map = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (map is! Map ||
      map['v'] != 1 ||
      map['k'] != 'r' ||
      map['i'] != messageId ||
      map['u'] != userId) {
    return null;
  }
  final Object? emoji = map['e'];
  return emoji is String &&
          emoji.isNotEmpty &&
          utf8.encode(emoji).length <= maxReactionEmojiBytes
      ? emoji
      : null;
}
