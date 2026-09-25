import '../../../core/failure.dart';

/// The platform's current answer to notification permission, read without
/// prompting (so it can be checked before deciding whether to ask at all).
enum PushPermissionStatus {
  /// Not yet asked: the explainer is worth showing.
  notDetermined,

  /// Refused, but the platform may still show its own prompt if asked
  /// again: the explainer is worth showing.
  denied,

  /// Already allowed, in full or provisionally: nothing left to ask for.
  authorized,
  provisional,
}

/// This device's push channel (implemented over Firebase Messaging in data/).
abstract interface class PushSource {
  /// Asks the member to allow notifications (Android 13+).
  ///
  /// Returns true when allowed. Asking again after a refusal must not nag:
  /// the platform decides whether a prompt shows.
  Future<bool> requestPermission();

  /// The current answer, without prompting.
  Future<PushPermissionStatus> permissionStatus();

  /// This device's push token, or null when the platform cannot provide one
  /// (no Play services, offline at first start).
  Future<String?> token();

  /// A new token whenever the platform rotates it.
  Stream<String> get tokenRefreshes;

  /// The conversation id of the notification that opened the app from a closed state,
  /// or null.
  Future<String?> launchConversation();

  /// Conversation ids of notifications tapped while the app is running in the background.
  Stream<String> get openedConversations;

  /// The member opened [conversationId]: its notification leaves the shade.
  Future<void> clearConversation(String conversationId);

  /// Sign-out: every notification of this account leaves the shade.
  Future<void> clearAll();

  /// The signed-in member is now [userId], or nobody. Called on every such
  /// change (never only on an explicit sign-out): whatever was kept for a
  /// previous member on this device -- the shade and any stored previews --
  /// must never be seen by, or merged into, whoever is signed in next.
  Future<void> forUser(String? userId);
}

/// Whether the member has already seen the explainer screen that runs before
/// SIS asks for notification permission (implemented over shared_preferences
/// in data/).
abstract interface class NotificationExplainerStore {
  /// True once the explainer has been shown, so it is never shown again.
  Future<bool> wasShown();

  Future<void> markShown();
}

/// The server's list of where to deliver (implemented over the Supabase RPCs
/// register_device_token / forget_device_token in data/).
abstract interface class PushRegistry {
  /// Claims this token for the signed-in member.
  ///
  /// The server keeps one device per member and drops the token from anyone else.
  Future<Result<void>> register(String token);

  /// Stops this device receiving the member's notifications.
  ///
  /// Called before signing out.
  Future<Result<void>> forget(String token);
}
