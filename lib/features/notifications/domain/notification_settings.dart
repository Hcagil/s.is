import '../../../core/failure.dart';

/// What the lock screen shows:
/// full = who and the message;
/// sender = only who it is from;
/// none = only that there is a new message.
enum NotificationPreview { full, sender, none }

/// A member with no saved settings has these defaults.
final class NotificationSettings {
  const NotificationSettings({
    this.enabled = true,
    this.preview = NotificationPreview.full,
  });

  final bool enabled;
  final NotificationPreview preview;

  NotificationSettings copyWith({bool? enabled, NotificationPreview? preview}) {
    return NotificationSettings(
      enabled: enabled ?? this.enabled,
      preview: preview ?? this.preview,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.enabled == enabled &&
      other.preview == preview;

  @override
  int get hashCode => Object.hash(enabled, preview);
}

/// A conversation mute silences one chat; a person mute silences that person
/// in every chat, groups included.
enum MuteKind { conversation, person }

/// A silenced conversation or person; until null means always.
final class Mute {
  const Mute({required this.kind, required this.target, this.until});

  final MuteKind kind;
  final String target;
  final DateTime? until;

  /// Whether the mute still silences anything at [now].
  bool activeAt(DateTime now) => until == null || until!.isAfter(now);
}

/// The lengths a member can pick from. A mute with no end (`until == null`)
/// can no longer be picked, but one already saved stays valid.
enum MuteLength {
  oneHour,
  eightHours,
  oneDay,
  threeDays,
  oneWeek;

  DateTime until(DateTime now) => switch (this) {
    oneHour => now.add(const Duration(hours: 1)),
    eightHours => now.add(const Duration(hours: 8)),
    oneDay => now.add(const Duration(days: 1)),
    threeDays => now.add(const Duration(days: 3)),
    oneWeek => now.add(const Duration(days: 7)),
  };
}

/// Which day a mute ends on, relative to now.
enum MuteDay { always, today, tomorrow, later }

/// When a mute ends: the day bucket plus the end time in local time
/// (`at` is null when the mute has no end).
({MuteDay day, DateTime? at}) muteEnd(DateTime? until, DateTime now) {
  if (until == null) return (day: MuteDay.always, at: null);
  final localUntil = until.toLocal();
  final localNow = now.toLocal();
  final day = DateTime(localUntil.year, localUntil.month, localUntil.day);
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  if (day == today) return (day: MuteDay.today, at: localUntil);
  if (day == DateTime(today.year, today.month, today.day + 1)) {
    return (day: MuteDay.tomorrow, at: localUntil);
  }
  return (day: MuteDay.later, at: localUntil);
}

/// The member's own notification settings and mutes; nobody else can read
/// them.
abstract interface class NotificationSettingsRepository {
  /// Defaults when nothing is saved.
  Future<Result<NotificationSettings>> load();

  Future<Result<void>> save(NotificationSettings settings);

  /// Every saved mute, expired ones included.
  Future<Result<List<Mute>>> mutes();

  /// Creates or replaces the mute.
  Future<Result<void>> mute(MuteKind kind, String target, DateTime? until);

  Future<Result<void>> unmute(MuteKind kind, String target);
}
