import '../domain/push.dart';

/// Push channel whose Firebase setup finishes after the first frame
/// (main.dart): every call waits for it, so nothing is lost -- a cold-start
/// notification tap is still read, just after the setup, and a failed setup
/// surfaces as the error of each call.
final class DeferredPushSource implements PushSource {
  DeferredPushSource(this._ready);

  final Future<PushSource> _ready;

  @override
  Future<bool> requestPermission() async => (await _ready).requestPermission();

  @override
  Future<PushPermissionStatus> permissionStatus() async =>
      (await _ready).permissionStatus();

  @override
  Future<String?> token() async => (await _ready).token();

  @override
  Stream<String> get tokenRefreshes async* {
    yield* (await _ready).tokenRefreshes;
  }

  @override
  Future<String?> launchConversation() async =>
      (await _ready).launchConversation();

  @override
  Stream<String> get openedConversations async* {
    yield* (await _ready).openedConversations;
  }

  @override
  Future<void> clearConversation(String conversationId) async =>
      (await _ready).clearConversation(conversationId);

  @override
  Future<void> clearAll() async => (await _ready).clearAll();

  @override
  Future<void> forUser(String? userId) async => (await _ready).forUser(userId);
}
