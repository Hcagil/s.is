import '../../../core/date_label.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/last_seen.dart';

/// The localised "last seen ..." line for [at], relative to [now].
String lastSeenText(AppLocalizations l, DateTime at, DateTime now) {
  final s = lastSeen(at, now);
  final local = at.toLocal();
  final time = '${twoDigit(local.hour)}:${twoDigit(local.minute)}';
  return switch (s.kind) {
    LastSeenKind.justNow => l.lastSeenJustNow,
    LastSeenKind.minutesAgo => l.lastSeenMinutes(s.minutes),
    LastSeenKind.today => l.lastSeenToday(time),
    LastSeenKind.yesterday => l.lastSeenYesterday(time),
    LastSeenKind.date => l.lastSeenDate(dateTail(at)),
  };
}
