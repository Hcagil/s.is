import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme.dart';
import '../../../core/date_label.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/timeline.dart';

/// The day chip's text: "Today", the day and month this year, else with the year.
String dayChipLabel(AppLocalizations l, DateTime at, DateTime now) {
  final local = at.toLocal();
  if (isSameLocalDay(at, now)) return l.dayChipToday;
  if (local.year == now.toLocal().year) {
    return DateFormat.MMMMd(l.localeName).format(local);
  }
  return DateFormat.yMMMMd(l.localeName).format(local);
}

/// The centred pill above the first message of a local day. Its 4 px padding plus the bubble's own 4 px margin make the 8 px gap.
class DayChip extends StatelessWidget {
  const DayChip({super.key, required this.at, required this.now});

  final DateTime at;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final b = SisBrand.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: b.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              dayChipLabel(AppLocalizations.of(context), at, now),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: b.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps an itemBuilder of the reversed message list: a row that starts a new local day gets a [DayChip] above it. The row keeps its own key (a Column holds both), and the loader row past the end is left alone.
IndexedWidgetBuilder withDayChips(
  List<TimelineEntry> timeline,
  IndexedWidgetBuilder rows,
) => (context, i) {
  final row = rows(context, i);
  if (i >= timeline.length) return row;
  final entry = timeline[timeline.length - 1 - i];
  final olderIndex = timeline.length - 2 - i;
  if (olderIndex >= 0 && isSameLocalDay(timeline[olderIndex].at, entry.at)) {
    return row;
  }
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DayChip(at: entry.at, now: DateTime.now()),
      row,
    ],
  );
};
