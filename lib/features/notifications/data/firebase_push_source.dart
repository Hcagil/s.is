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
  final d = message.data;
  final id = d['conversation_id'], title = d['title'], body = d['body'];
  if (id is! String || title is! String || body is! String) return;
  await LocalPushDisplay.init();
  await LocalPushDisplay.show(conversationId: id, title: title, body: body);
}

/// The device side of push; thin on purpose (ARCHITECTURE rule 4), verified
/// on a device. While the app is open nothing is shown: the chat list already
/// says what is new.
final class FirebasePushSource implements PushSource {
  FirebasePushSource(this._messaging);

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
  Future<String?> launchConversation() => LocalPushDisplay.launchConversation();

  @override
  Stream<String> get openedConversations => _taps.stream;

  @override
  Future<void> clearConversation(String conversationId) =>
      LocalPushDisplay.clear(conversationId);

  @override
  Future<void> clearAll() => LocalPushDisplay.clearAll();
}
