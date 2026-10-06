import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse;

import '../../chat/domain/message.dart' show randomMessageId;
import '../domain/notification_action.dart';
import 'local_push_display.dart';
import 'notification_action_api.dart';
import 'push_receipt_log.dart';

/// A tap on a notification button (Mark as read, Reply) on Android, run in the
/// background isolate the notifications plugin starts (registered through
/// LocalPushDisplay.init in main). That isolate has no Supabase session, so the
/// button goes to the server with the action token the push carried
/// (NotificationActionApi). A failed send is tried once more; the reply keeps
/// the same message id, so the server never stores it twice. The notification
/// is then updated by LocalPushDisplay.afterAction.
@pragma('vm:entry-point')
Future<void> onNotificationAction(NotificationResponse response) async {
  try {
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {}
  try {
    await LocalPushDisplay.init();
    final conversationId = response.payload;
    final ticket = conversationId == null || conversationId.isEmpty
        ? null
        : await LocalPushDisplay.ticketFor(conversationId);
    final action = NotificationAction.fromResponse(
      actionId: response.actionId,
      conversationId: conversationId,
      ticket: ticket,
      input: response.input,
      newId: randomMessageId,
    );
    if (action == null) return;
    final api = NotificationActionApi();
    var result = await api.send(action);
    if (result == NotificationActionResult.retry) {
      result = await api.send(action);
    }
    await LocalPushDisplay.afterAction(action, result);
  } catch (e) {
    await PushReceiptLog.add('error', error: e, label: 'notification action');
  }
}
