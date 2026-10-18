import 'package:intl/intl.dart';

import '../../../core/date_label.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/message.dart';

/// The read time on the readers card, relative to [now] (passed in, so a test sets the clock): the clock time today, "yesterday at ..." yesterday, "Oct 16 at ..." within 365 days, else dd.MM.yy.
String seenTime(AppLocalizations l, DateTime at, DateTime now) {
  final time = clockTime(at);
  if (isSameLocalDay(at, now)) return time;
  final n = now.toLocal();
  if (isSameLocalDay(at, DateTime(n.year, n.month, n.day - 1))) {
    return l.seenYesterdayAt(time);
  }
  final date = now.difference(at).inDays < 365
      ? DateFormat.MMMd(l.localeName).format(at.toLocal())
      : dateTail(at);
  return l.seenDateAt(date, time);
}
