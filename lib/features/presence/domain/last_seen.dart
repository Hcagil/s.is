import '../../../core/date_label.dart';

/// Which wording a "last seen" line needs.
enum LastSeenKind { justNow, minutesAgo, today, yesterday, date }

typedef LastSeen = ({LastSeenKind kind, int minutes, DateTime at});

/// Which "last seen" wording applies to a member last online at [at],
/// relative to [now]: just now, N min ago, today, yesterday, else a date.
/// Formatting the words is presentation's job (`lastSeenText`).
LastSeen lastSeen(DateTime at, DateTime now) {
  final today = now.toLocal();
  final ago = today.difference(at.toLocal());
  // A future time is clock skew between phone and server: treat it as now.
  if (ago.inMinutes < 1) {
    return (kind: LastSeenKind.justNow, minutes: 0, at: at);
  }
  if (ago.inMinutes < 60) {
    return (kind: LastSeenKind.minutesAgo, minutes: ago.inMinutes, at: at);
  }
  if (isSameLocalDay(at, now)) {
    return (kind: LastSeenKind.today, minutes: 0, at: at);
  }
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  if (isSameLocalDay(at, yesterday)) {
    return (kind: LastSeenKind.yesterday, minutes: 0, at: at);
  }
  return (kind: LastSeenKind.date, minutes: 0, at: at);
}
