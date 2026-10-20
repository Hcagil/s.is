import 'dart:convert';

import 'link_preview.dart';

/// The longest card link kept in a locked message.
const int maxEnvelopeUrl = 2000;

/// The JSON text that is locked (Olm-encrypted) for a text message: `{"v":1,"i":id,"t":text,"lp":card or null}`. [id] is the message's row id (the receiver rejects a locked text whose id differs from its row). The card carries url, title, description, site and video only, each capped (LinkPreview.maxTitle/LinkPreview.maxDescription/LinkPreview.maxSite UTF-16 units); its picture path is never included. A card whose url is longer than [maxEnvelopeUrl] is left out (lp null).
String encodeEnvelope({
  required String id,
  required String text,
  LinkPreview? card,
}) {
  final Map<String, Object?> map = {
    'v': 1,
    'i': id,
    't': text,
    'lp': card == null || card.url.toString().length > maxEnvelopeUrl
        ? null
        : {
            'url': card.url.toString(),
            'title': _cap(card.title, LinkPreview.maxTitle),
            if (card.description != null)
              'description': _cap(
                card.description!,
                LinkPreview.maxDescription,
              ),
            if (card.site != null)
              'site': _cap(card.site!, LinkPreview.maxSite),
            if (card.video) 'video': true,
          },
  };
  return jsonEncode(map);
}

/// Reads the JSON text [json] that [encodeEnvelope] made for the message [id]. Null (never a throw) when it is not valid JSON, not an object, `v` is not 1, `i` is not exactly [id] (a copy of another message replayed into this row), or `t` is not a string. The card is null when `lp` is absent or not a valid card (LinkPreview.fromJson); it never has a picture.
({String text, LinkPreview? card})? decodeEnvelope(String json, String id) {
  final Object? map;
  try {
    map = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (map is! Map || map['v'] != 1 || map['i'] != id) return null;
  final text = map['t'];
  if (text is! String) return null;
  return (text: text, card: LinkPreview.fromJson(map['lp']));
}

/// Cuts [s] to [max] UTF-16 units without splitting a surrogate pair.
String _cap(String s, int max) {
  if (s.length <= max) return s;
  final String capped = s.substring(0, max);
  final int last = capped.codeUnitAt(capped.length - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    return capped.substring(0, capped.length - 1);
  }
  return capped;
}
