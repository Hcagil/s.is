import '../../../core/date_label.dart';

/// "last seen …" for a member last online at [at], relative to [now]: just
/// now, N min ago, today/yesterday at HH:mm, else the same dd.MM.yy date the conversation list uses.
String lastSeenLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = now.toLocal();
  final ago = today.difference(local);
  // A future time is clock skew between phone and server: treat it as now.
  if (ago.inMinutes < 1) return 'last seen just now';
  if (ago.inMinutes < 60) return 'last seen ${ago.inMinutes} min ago';
  final time = '${twoDigit(local.hour)}:${twoDigit(local.minute)}';
  if (isSameLocalDay(at, now)) return 'last seen today at $time';
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  if (isSameLocalDay(at, yesterday)) return 'last seen yesterday at $time';
  return 'last seen ${dateTail(at)}';
}
