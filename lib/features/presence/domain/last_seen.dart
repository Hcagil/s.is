/// "last seen …" for a member last online at [at], relative to [now]:
/// just now, N min ago, today at HH:mm, yesterday at HH:mm, then a date in
/// the same dd.MM.yy form the conversation list uses.
String lastSeenLabel(DateTime at, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = at.toLocal();
  final today = now.toLocal();
  final ago = today.difference(local);
  // A future time is clock skew between phone and server: treat it as now.
  if (ago.inMinutes < 1) return 'last seen just now';
  if (ago.inMinutes < 60) return 'last seen ${ago.inMinutes} min ago';
  final day = DateTime(local.year, local.month, local.day);
  final todayStart = DateTime(today.year, today.month, today.day);
  final time = '${two(local.hour)}:${two(local.minute)}';
  if (day == todayStart) return 'last seen today at $time';
  if (day == DateTime(today.year, today.month, today.day - 1)) {
    return 'last seen yesterday at $time';
  }
  return 'last seen ${two(local.day)}.${two(local.month)}.${two(local.year % 100)}';
}
