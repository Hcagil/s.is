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
  const MessageEntry(this.message, [this.album = const []]);

  final Message message;

  /// For a photo album: all its photos, oldest first, [message] being the first. Empty for any other message.
  final List<Message> album;

  bool get isAlbum => album.length >= 2;

  @override
  DateTime get at => message.createdAt;
}

final class EventEntry extends TimelineEntry {
  const EventEntry(this.event);

  final GroupEvent event;

  @override
  DateTime get at => event.createdAt;
}

/// A "security code changed" line in a 1:1: the contact's key changed on this phone at [changedAt]. [wasVerified]: the contact was marked verified before.
final class KeyChangeEntry extends TimelineEntry {
  const KeyChangeEntry({
    required this.peerUserId,
    required this.changedAt,
    required this.wasVerified,
  });

  final String peerUserId;
  final DateTime changedAt;
  final bool wasVerified;

  @override
  DateTime get at => changedAt;
}

/// [messages] (oldest first) merged with [events] (any order; empty for
/// anyone but a current admin, since the server already refuses the rows to
/// everyone else), sorted by time. Stable for equal timestamps -- a message
/// keeps its place ahead of an event sharing its exact instant, and events
/// keep their relative order among themselves.
///
/// Two or more consecutive photos from one sender sharing a photoGroup are
/// folded into one [MessageEntry] carrying the whole album.
List<TimelineEntry> buildTimeline(
  List<Message> messages,
  List<GroupEvent> events, {
  List<KeyChangeEntry> keyChanges = const [],
}) {
  var i = 0;
  final folded = <MessageEntry>[];
  while (i < messages.length) {
    final m = messages[i];
    if (m.photoGroup == null || m.isDeleted || !m.hasAttachment) {
      folded.add(MessageEntry(m));
      i++;
      continue;
    }
    var j = i + 1;
    while (j < messages.length &&
        messages[j].photoGroup == m.photoGroup &&
        messages[j].senderId == m.senderId &&
        !messages[j].isDeleted &&
        messages[j].hasAttachment) {
      j++;
    }
    final run = messages.sublist(i, j);
    folded.add(
      run.length >= 2 ? MessageEntry(run.first, run) : MessageEntry(m),
    );
    i = j;
  }
  final entries = <TimelineEntry>[
    ...folded,
    for (final e in events) EventEntry(e),
    ...keyChanges,
  ];
  entries.sort((a, b) => a.at.compareTo(b.at));
  return entries;
}

/// The photos of the album [m] belongs to, oldest first -- [m] itself when it is not part of one. Matches on the shared photoGroup and the sender, ignoring photos deleted for everyone.
List<Message> albumOf(List<Message> messages, Message m) {
  final group = m.photoGroup;
  if (group == null) return [m];
  final run = [
    for (final x in messages)
      if (x.photoGroup == group &&
          x.senderId == m.senderId &&
          !x.isDeleted &&
          x.hasAttachment)
        x,
  ];
  return run.length >= 2 ? run : [m];
}
