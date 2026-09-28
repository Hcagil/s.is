import 'group_event.dart';
import 'message.dart';

/// One line the message screen draws, in order: either a message or an
/// admin-only group event ("X left", "X was removed", "X was added"). A
/// sealed type instead of two separate lists, so the widget never has to
/// re-derive the interleaving itself -- see [buildTimeline].
sealed class TimelineEntry {
  const TimelineEntry();

  DateTime get at;
}

final class MessageEntry extends TimelineEntry {
  const MessageEntry(this.message);

  final Message message;

  @override
  DateTime get at => message.createdAt;
}

final class EventEntry extends TimelineEntry {
  const EventEntry(this.event);

  final GroupEvent event;

  @override
  DateTime get at => event.createdAt;
}

/// [messages] (oldest first) merged with [events] (any order; empty for
/// anyone but a current admin, since the server already refuses the rows to
/// everyone else), sorted by time. Stable for equal timestamps -- a message
/// keeps its place ahead of an event sharing its exact instant, and events
/// keep their relative order among themselves.
List<TimelineEntry> buildTimeline(
  List<Message> messages,
  List<GroupEvent> events,
) {
  final entries = <TimelineEntry>[
    for (final m in messages) MessageEntry(m),
    for (final e in events) EventEntry(e),
  ];
  entries.sort((a, b) => a.at.compareTo(b.at));
  return entries;
}
