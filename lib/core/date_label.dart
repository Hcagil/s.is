/// Zero-pads [v] to two digits, e.g. 3 -> "03".
String twoDigit(int v) => v.toString().padLeft(2, '0');

/// Whether [at] and [now] fall on the same local calendar day.
bool isSameLocalDay(DateTime at, DateTime now) =>
    at.toLocal().year == now.toLocal().year &&
    at.toLocal().month == now.toLocal().month &&
    at.toLocal().day == now.toLocal().day;

/// [at]'s local date as dd.MM.yy, used by chat previews and "last seen".
String dateTail(DateTime at) =>
    '${twoDigit(at.toLocal().day)}.'
    '${twoDigit(at.toLocal().month)}.${twoDigit(at.toLocal().year % 100)}';
