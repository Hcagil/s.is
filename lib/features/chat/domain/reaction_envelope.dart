import 'dart:convert';

/// The exact UTF-8 length of a reaction envelope; shorter ones are padded so the ciphertext length reveals nothing about the emoji.
const int reactionEnvelopeBytes = 128;

/// The JSON text that is locked for a reaction: `{"v":1,"k":"r","i":messageId,"u":userId,"e":emoji,"p":padding}`. The padding is spaces inside the string `p`, so the UTF-8 length is exactly [reactionEnvelopeBytes] (ids are 36 characters and the server caps an emoji at 64 bytes, so it always fits). A reaction envelope has no `t`, so decodeEnvelope refuses it.
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

/// Reads the JSON text [json] that [encodeReactionEnvelope] made for the reaction of [userId] to [messageId]. Null (never a throw) when it is not valid JSON, not an object, `v` is not 1, `k` is not 'r' (a message envelope has no `k`), `i` is not exactly [messageId], `u` is not exactly [userId] (a copy of another reaction replayed into this row), or `e` is not a non-empty string.
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
  return emoji is String && emoji.isNotEmpty ? emoji : null;
}
