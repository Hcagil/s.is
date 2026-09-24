import 'package:firebase_messaging/firebase_messaging.dart';

import '../domain/push.dart';

/// The device side of push; thin on purpose (ARCHITECTURE rule 4), verified on a device.
///
/// The notification's data carries conversation_id; nothing else is read from it.
final class FirebasePushSource implements PushSource {
  FirebasePushSource(this._messaging);

  final FirebaseMessaging _messaging;

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
    final m = await _messaging.getInitialMessage();
    return _conversationOf(m);
  }

  @override
  Stream<String> get openedConversations => FirebaseMessaging.onMessageOpenedApp
      .map(_conversationOf)
      .where((id) => id != null)
      .cast<String>();

  static String? _conversationOf(RemoteMessage? m) {
    final id = m?.data['conversation_id'];
    return id is String && id.isNotEmpty ? id : null;
  }
}
