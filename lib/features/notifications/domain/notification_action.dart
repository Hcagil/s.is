/// The notification buttons a push can carry.
enum NotificationActionKind { markRead, reply }

/// Id of the "Mark as read" button.
const markReadActionId = 'sis.mark_read';

/// Id of the "Reply" button.
const replyActionId = 'sis.reply';

/// The longest reply the database accepts (messages.body check).
const _maxReplyLength = 4000;

/// What a push's buttons need to reach the server without a session: the
/// action token notify-on-message signed into the push, and the address of
/// the notification-action function.
final class ActionTicket {
  const ActionTicket({required this.token, required this.url});

  /// Opaque to the phone; the server checks it.
  final String token;

  /// Always https.
  final String url;

  /// From a push's data block; null when either key is missing or odd (an
  /// older server sends none, and then the notification shows no buttons).
  static ActionTicket? fromPush(Map<String, Object?> data) =>
      _make(data['action_token'], data['action_url']);

  Map<String, String> toJson() => {'t': token, 'u': url};

  /// From [toJson]'s map; null for anything else. Never throws.
  static ActionTicket? fromJson(Object? j) =>
      j is Map ? _make(j['t'], j['u']) : null;

  static ActionTicket? _make(Object? token, Object? url) {
    if (token is! String || token.isEmpty) return null;
    if (url is! String || !url.startsWith('https://')) return null;
    return ActionTicket(token: token, url: url);
  }
}

/// How the server answered a button.
enum NotificationActionResult {
  /// Accepted, or already done by an earlier identical attempt.
  done,

  /// Refused for good: bad or expired token, no longer allowed, id in use.
  rejected,

  /// No answer or a passing failure (offline, rate limited, server error).
  retry,
}

/// One tap on a notification button, ready to send.
final class NotificationAction {
  const NotificationAction._({
    required this.kind,
    required this.conversationId,
    required this.ticket,
    this.text,
    this.messageId,
  });

  final NotificationActionKind kind;
  final String conversationId;
  final ActionTicket ticket;

  /// The reply, trimmed; null for mark as read.
  final String? text;

  /// The reply's client-generated id: the server stores one message per id,
  /// so sending the same action again never duplicates it.
  final String? messageId;

  /// The action for a tapped button, or null when there is nothing to send:
  /// no chat or ticket, an unknown button, or a reply that is empty or longer
  /// than the database allows. [newId] makes the reply's message id.
  static NotificationAction? fromResponse({
    required String? actionId,
    required String? conversationId,
    required ActionTicket? ticket,
    String? input,
    required String Function() newId,
  }) {
    if (conversationId == null || conversationId.isEmpty || ticket == null) {
      return null;
    }
    if (actionId == markReadActionId) {
      return NotificationAction._(
        kind: NotificationActionKind.markRead,
        conversationId: conversationId,
        ticket: ticket,
      );
    }
    if (actionId != replyActionId) return null;
    final text = input?.trim();
    if (text == null || text.isEmpty || text.length > _maxReplyLength) {
      return null;
    }
    return NotificationAction._(
      kind: NotificationActionKind.reply,
      conversationId: conversationId,
      ticket: ticket,
      text: text,
      messageId: newId(),
    );
  }

  /// The JSON body notification-action expects.
  Map<String, Object> toRequest() => {
    'token': ticket.token,
    'conversation_id': conversationId,
    'action': kind == NotificationActionKind.markRead ? 'mark_read' : 'reply',
    if (kind == NotificationActionKind.reply) ...{
      'id': messageId!,
      'body': text!,
    },
  };
}

/// The words on the buttons and in the follow-up line.
final class NotificationActionLabels {
  const NotificationActionLabels({
    required this.markRead,
    required this.reply,
    required this.replyHint,
    required this.notSent,
  });

  final String markRead;
  final String reply;

  /// The hint in the reply box.
  final String replyHint;

  /// Prefix of the line shown when a reply could not be sent.
  final String notSent;
}

/// The labels for [languageCode] ('tr' or anything else for English). The
/// background isolate has no app context, so this follows the phone's
/// language, as the native notification does.
NotificationActionLabels notificationActionLabels(String languageCode) =>
    languageCode == 'tr'
    ? const NotificationActionLabels(
        markRead: 'Okundu olarak işaretle',
        reply: 'Yanıtla',
        replyHint: 'Mesaj',
        notSent: 'Gönderilemedi',
      )
    : const NotificationActionLabels(
        markRead: 'Mark as read',
        reply: 'Reply',
        replyHint: 'Message',
        notSent: 'Not sent',
      );
