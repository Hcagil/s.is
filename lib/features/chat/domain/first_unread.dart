import 'message.dart';

/// Id of the first unread message of a chat that just opened, or null.
/// [messages] is oldest first. [unread] is the server's count of other people's messages not yet read: the first unread message is the [unread]-th newest message not sent by [me].
String? firstUnreadId(List<Message> messages, int unread, String? me) {
  if (unread <= 0 || me == null || messages.isEmpty) return null;
  var count = 0;
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (!m.isFrom(me)) {
      count++;
      if (count == unread) return m.id;
    }
  }
  // shortcut: older page not loaded, so no line; upgrade if long unread runs matter.
  return null;
}
