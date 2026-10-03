/// True for a message of 1-3 emoji and nothing else (whitespace ignored): the
/// bubble then shows it large. Text-default symbols ((c), (R), TM) and a bare
/// digit are not emoji unless followed by U+FE0F, or a keycap.
bool isBigEmoji(String text) =>
    _emojiOnly.hasMatch(text.replaceAll(RegExp(r'\s+'), ''));

// One pictograph, optionally with a variation selector or a skin tone.
const _picto =
    r'(?:(?:(?=[\u{2600}-\u{10FFFF}])\p{Extended_Pictographic}'
    r'|\p{Extended_Pictographic}(?=️))'
    r'(?:️|\p{Emoji_Modifier})?)';

// A flag, a keycap, the England/Scotland/Wales tag flags, or a pictograph
// sequence joined with U+200D (family, profession, ...).
const _unit =
    r'(?:\p{Regional_Indicator}{2}'
    r'|[0-9#*]️?⃣'
    r'|\u{1F3F4}[\u{E0020}-\u{E007E}]+\u{E007F}'
    '|$_picto(?:\\u200D$_picto)*)';

final _emojiOnly = RegExp('^(?:$_unit){1,3}\$', unicode: true);
