/// Sound and vibration choices for new-message notifications. Stored on the
/// phone only; see AlertStore.
enum AlertChoice {
  byDefault,
  on,
  off;

  /// This choice against the [fallback] the global setting gives.
  bool resolve(bool fallback) => switch (this) {
    byDefault => fallback,
    on => true,
    off => false,
  };
}

/// The member's global sound and vibration settings.
final class AlertDefaults {
  const AlertDefaults({
    this.sound = true,
    this.tone,
    this.toneName,
    this.vibration = true,
  });

  final bool sound;

  /// The chosen tone's URI; null is the system default notification sound.
  final String? tone;

  /// The chosen tone's display name; null for the system default.
  final String? toneName;

  final bool vibration;

  AlertDefaults copyWith({bool? sound, bool? vibration}) => AlertDefaults(
    sound: sound ?? this.sound,
    tone: tone,
    toneName: toneName,
    vibration: vibration ?? this.vibration,
  );

  /// Sets both tone and name, either of them to null.
  AlertDefaults withTone(String? tone, String? toneName) => AlertDefaults(
    sound: sound,
    tone: tone,
    toneName: toneName,
    vibration: vibration,
  );

  Map<String, Object?> toJson() => {
    's': sound,
    't': tone,
    'n': toneName,
    'v': vibration,
  };

  static AlertDefaults fromJson(Map<String, Object?> j) => AlertDefaults(
    sound: j['s'] as bool? ?? true,
    tone: j['t'] as String?,
    toneName: j['n'] as String?,
    vibration: j['v'] as bool? ?? true,
  );

  @override
  bool operator ==(Object other) =>
      other is AlertDefaults &&
      other.sound == sound &&
      other.tone == tone &&
      other.toneName == toneName &&
      other.vibration == vibration;

  @override
  int get hashCode => Object.hash(sound, tone, toneName, vibration);
}

/// One chat's own sound and vibration choices.
final class ChatAlert {
  const ChatAlert({
    this.sound = AlertChoice.byDefault,
    this.vibration = AlertChoice.byDefault,
  });

  final AlertChoice sound;
  final AlertChoice vibration;

  bool get isDefault =>
      sound == AlertChoice.byDefault && vibration == AlertChoice.byDefault;

  ChatAlert copyWith({AlertChoice? sound, AlertChoice? vibration}) => ChatAlert(
    sound: sound ?? this.sound,
    vibration: vibration ?? this.vibration,
  );

  Map<String, Object?> toJson() => {'s': sound.name, 'v': vibration.name};

  /// Tolerant: a missing or unknown name reads as default.
  static ChatAlert fromJson(Map<String, Object?> j) =>
      ChatAlert(sound: _choice(j['s']), vibration: _choice(j['v']));

  static AlertChoice _choice(Object? name) => AlertChoice.values.firstWhere(
    (c) => c.name == name,
    orElse: () => AlertChoice.byDefault,
  );

  @override
  bool operator ==(Object other) =>
      other is ChatAlert &&
      other.sound == sound &&
      other.vibration == vibration;

  @override
  int get hashCode => Object.hash(sound, vibration);
}

/// What one notification actually does, after the chat's choices met the
/// defaults.
final class EffectiveAlert {
  const EffectiveAlert({
    required this.sound,
    required this.tone,
    required this.vibration,
  });

  final bool sound;

  /// Tone URI; null is the system default. Always null when [sound] is off.
  final String? tone;
  final bool vibration;

  @override
  bool operator ==(Object other) =>
      other is EffectiveAlert &&
      other.sound == sound &&
      other.tone == tone &&
      other.vibration == vibration;

  @override
  int get hashCode => Object.hash(sound, tone, vibration);
}

/// Default -> effective: a chat left on Default follows [d].
EffectiveAlert resolveAlert(AlertDefaults d, ChatAlert c) {
  final sound = c.sound.resolve(d.sound);
  return EffectiveAlert(
    sound: sound,
    tone: sound ? d.tone : null,
    vibration: c.vibration.resolve(d.vibration),
  );
}

/// Every alerting channel's id starts with this.
const alertChannelPrefix = 'msg-';

/// The stable Android channel id of a combination, e.g. 'msg-sys-v1',
/// 'msg-off-v0', 'msg-1a2b3c4d-v1' (a custom tone, hashed).
String alertChannelId(EffectiveAlert a) {
  final tone = !a.sound
      ? 'off'
      : a.tone == null
      ? 'sys'
      : _fnv1a(a.tone!);
  return '$alertChannelPrefix$tone-v${a.vibration ? 1 : 0}';
}

/// The channels still needed: the defaults' and every chat's own.
Set<String> usedAlertChannelIds(
  AlertDefaults d,
  Map<String, ChatAlert> chats,
) => {
  for (final c in [const ChatAlert(), ...chats.values])
    alertChannelId(resolveAlert(d, c)),
};

/// FNV-1a: stable across app versions, unlike String.hashCode.
String _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16);
}

/// The phone-only store of the defaults and the chats' own choices.
abstract interface class AlertStore {
  Future<AlertDefaults> loadDefaults();

  Future<void> saveDefaults(AlertDefaults d);

  /// Only the chats that differ from Default, by conversation id.
  Future<Map<String, ChatAlert>> loadChats();

  /// Removes the chat's entry when [c] is all Default.
  Future<void> saveChat(String conversationId, ChatAlert c);
}

/// A tone the member picked.
final class PickedTone {
  const PickedTone({required this.tone, required this.name});

  /// The tone's URI; null is the system default.
  final String? tone;
  final String name;
}

/// The phone's notification-sound chooser (Android only).
abstract interface class TonePicker {
  /// Null when the member cancelled.
  Future<PickedTone?> pick(String? currentTone);
}
