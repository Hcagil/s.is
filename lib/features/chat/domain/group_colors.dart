/// How many colour slots a group has. Mirrors the server's 0..9 range
/// (conversation_members.color_slot, assigned by a trigger).
const groupColorSlots = 10;

/// Name colours (0xAARRGGBB), one per slot, for the light theme: each is at
/// least 4.5:1 (WCAG AA) on the other side's bubble (white) and on the page.
const _light = <int>[
  0xFFC62828,
  0xFFB45309,
  0xFF8A6100,
  0xFF2E7D32,
  0xFF00796B,
  0xFF00778F,
  0xFF1565C0,
  0xFF5E35B1,
  0xFF9C27B0,
  0xFFAD1457,
];

/// ...and for the dark theme, on the dark bubble 0xFF1D1A42.
const _dark = <int>[
  0xFFFF8A80,
  0xFFFFB74D,
  0xFFE6D15C,
  0xFF81C784,
  0xFF4DD0C0,
  0xFF4DD0E1,
  0xFF64B5F6,
  0xFFB39DDB,
  0xFFE08BF0,
  0xFFF48FB1,
];

/// The colour of [slot] as 0xAARRGGBB. A slot outside 0..9 wraps (never throws).
int groupColorArgb(int slot, {required bool dark}) =>
    (dark ? _dark : _light)[slot % groupColorSlots];

/// A group member as the conversation list needs to draw them: their name and
/// colour slot.
final class GroupVoice {
  const GroupVoice(this.name, this.slot);
  final String name;
  final int slot;
  Map<String, Object?> toJson() => {'name': name, 'slot': slot};
  static GroupVoice fromJson(Map<String, Object?> json) =>
      GroupVoice(json['name'] as String, json['slot'] as int);
}
