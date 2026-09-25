import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';

import '../domain/push.dart';
import 'local_push_display.dart';

/// A push while the app is in the background or closed. Pushes carry data
/// only (the chat, and the title and body the server worded for this
/// member's preview setting), so the app shows them itself, grouped into one
/// SIS notification. Registered in main; runs in its own isolate.
@pragma('vm:entry-point')
Future<void> onBackgroundPush(RemoteMessage message) async {
  // A notification block means Android already drew this one itself (an
  // older build, or this device's shows_itself was still false when it was
  // sent): showing it again here would duplicate it.
  if (message.notification != null) return;
  final d = message.data;
  final id = d['conversation_id'], title = d['title'], body = d['body'];
  if (id is! String || title is! String || body is! String) return;
  final targetUser = d['user_id'];
  if (targetUser is String &&
      targetUser != await LocalPushDisplay.currentOwner()) {
    return;
  }
  await LocalPushDisplay.init();
  await LocalPushDisplay.show(conversationId: id, title: title, body: body);
}

/// The device side of push; thin on purpose (ARCHITECTURE rule 4), verified
/// on a device. While the app is open nothing is shown: the chat list already
/// says what is new.
final class FirebasePushSource implements PushSource {
  FirebasePushSource(this._messaging) {
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
  Future<String?> token() async {
    try {
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
