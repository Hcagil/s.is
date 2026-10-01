import 'dart:async';
import 'dart:ui';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import '../domain/push.dart';
import 'local_push_display.dart';
import 'push_receipt_log.dart';

/// A push while the app is in the background or closed. Pushes carry data
/// only (the chat, and the title and body the server worded for this
/// member's preview setting), so the app shows them itself, grouped into one
/// SIS notification. Registered in main; runs in its own isolate, which has
/// no Supabase session: what happens to each push is kept as a receipt
/// (PushReceiptLog) and uploaded by the app on its next open.
///
/// Every push that reaches here ends in exactly one terminal receipt: shown,
/// `dropped:reason`, or error. `shown` means the push's line is stored and a
/// posted notification includes it: pushes of one burst are coalesced
/// (LocalPushDisplay.show), so a later push's post may be the one that shows
/// an earlier line, and each still records its own `shown`.
@pragma('vm:entry-point')
Future<void> onBackgroundPush(RemoteMessage message) async {
  try {
    // The plugins this isolate uses (shared preferences, notifications).
    DartPluginRegistrant.ensureInitialized();
  } catch (_) {}
  final raw = message.data['message_id'];
  final messageId = raw is String ? raw : null;
  // Timings for the receipt (where a late push was late): when FCM sent it,
  // when it reached the phone (PushArrivalReceiver.kt), and now, when the
  // Dart handler starts; all epoch milliseconds, never message content.
  final arrival = await PushReceiptLog.takeArrival(messageId);
  await PushReceiptLog.add(
    'received',
    messageId: messageId,
    note:
        'sent=${message.sentTime?.millisecondsSinceEpoch ?? '?'} '
        'dart=${DateTime.now().millisecondsSinceEpoch} '
        '${arrival ?? 'native=?'}',
  );
  try {
    // Android already drew and alerted for this push (InstantPush.kt): this
    // post replaces it in place, quietly.
    await PushReceiptLog.add(
      await _deliver(
        message,
        alreadyAlerted: arrival?.contains('fast=native') ?? false,
      ),
      messageId: messageId,
    );
  } catch (e) {
    // Never rethrown into the plugin, never swallowed unreported.
    await PushReceiptLog.add('error', messageId: messageId, error: e);
  }
}

/// Shows the push; returns its terminal stage, `shown` or `dropped:reason`.
Future<String> _deliver(
  RemoteMessage message, {
  bool alreadyAlerted = false,
}) async {
  // A notification block means Android already drew this one itself (an
  // older build, or this device's shows_itself was still false when it was
  // sent): showing it again here would duplicate it.
  if (message.notification != null) return 'dropped:has_notification';
  final d = message.data;
  final id = d['conversation_id'], title = d['title'], body = d['body'];
  if (id is! String || title is! String || body is! String) {
    return 'dropped:missing_fields';
  }
  final owner = await LocalPushDisplay.currentOwner();
  if (owner == null) return 'dropped:no_owner';
  final targetUser = d['user_id'];
  if (targetUser is String && targetUser != owner) {
    return 'dropped:owner_mismatch';
  }
  await LocalPushDisplay.init();
  if (!await LocalPushDisplay.notificationsEnabled()) {
    return 'dropped:notifications_off';
  }
  final sender = d['sender'], chat = d['chat'];
  final drawn = await LocalPushDisplay.show(
    conversationId: id,
    title: title,
    body: body,
    sender: sender is String && sender.isNotEmpty ? sender : null,
    chat: chat is String && chat.isNotEmpty ? chat : null,
    alreadyAlerted: alreadyAlerted,
  );
  return drawn ? 'shown' : 'dropped:no_owner';
}

/// The device side of push; thin on purpose (ARCHITECTURE rule 4), verified
/// on a device. While the app is open nothing is shown: the chat list already
/// says what is new.
final class FirebasePushSource implements PushSource {
  FirebasePushSource(this._messaging) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // While the app is open nothing is shown, as on Android: pin the system
      // alert off so an iPhone shows nothing on top of the app.
      unawaited(_messaging.setForegroundNotificationPresentationOptions());
    }
    // A tap on a notification Android drew itself (this device's
    // shows_itself was still false when the push arrived): the same path
    // LocalPushDisplay taps already use.
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final id = _conversationOf(m);
      if (id != null) _taps.add(id);
    });
  }

  final FirebaseMessaging _messaging;

  static final _taps = StreamController<String>.broadcast();

  /// Given to LocalPushDisplay.init in main: a notification tapped while the
  /// app runs.
  static void tapped(String conversationId) => _taps.add(conversationId);

  @override
  Future<bool> requestPermission() async {
    final s = await _messaging.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<PushPermissionStatus> permissionStatus() async {
    final s = await _messaging.getNotificationSettings();
    return switch (s.authorizationStatus) {
      AuthorizationStatus.authorized => PushPermissionStatus.authorized,
      AuthorizationStatus.provisional => PushPermissionStatus.provisional,
      // deniedPermanently is not reported by iOS or Android in practice; read
      // the same as a plain denial, which the explainer can still act on.
      AuthorizationStatus.denied ||
      AuthorizationStatus.deniedPermanently => PushPermissionStatus.denied,
      AuthorizationStatus.notDetermined => PushPermissionStatus.notDetermined,
    };
  }

  @override
  Future<String?> token() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // The APNs token arrives shortly after launch; getToken fails
        // without it. Waits up to ~10 s, then gives up: a token refresh
        // registers it later (PushRegistration listens to those).
        for (
          var i = 0;
          i < 20 && await _messaging.getAPNSToken() == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      return await _messaging.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Future<String?> launchConversation() async {
    final local = await LocalPushDisplay.launchConversation();
    if (local != null) return local;
    // Cold start via a notification Android drew itself.
    return _conversationOf(await _messaging.getInitialMessage());
  }

  @override
  Stream<String> get openedConversations => _taps.stream;

  @override
  Future<void> clearConversation(String conversationId) =>
      LocalPushDisplay.clear(conversationId);

  @override
  Future<void> clearAll() => LocalPushDisplay.clearAll();

  @override
  Future<void> forUser(String? userId) => LocalPushDisplay.forUser(userId);

  static String? _conversationOf(RemoteMessage? m) {
    final id = m?.data['conversation_id'];
    return id is String && id.isNotEmpty ? id : null;
  }
}
