import 'message.dart';

/// Id of the first unread message of a chat that just opened, or null.
/// [messages] is oldest first. [unread] is the server's count of other people's messages not yet read: the first unread message is the [unread]-th newest message not sent by [me].
/// [orOldest] makes the function return the oldest other-person message when fewer than [unread] are loaded, instead of null.
String? firstUnreadId(
  List<Message> messages,
  int unread,
  String? me, {
  bool orOldest = false,
}) {
  if (unread <= 0 || me == null || messages.isEmpty) return null;
  var count = 0;
  String? oldest;
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (!m.isFrom(me)) {
      count++;
      oldest = m.id;
      if (count == unread) return m.id;
    }
  }
  // Fewer than [unread] such rows are loaded: with [orOldest] (the load cap was reached or the chat's start is loaded) the oldest one is the answer, else null so the caller loads older rows.
  return orOldest ? oldest : null;
}
