import '../../../core/failure.dart';
import 'member.dart';

/// Authentication boundary; the only way the app talks to the identity provider.
abstract interface class AuthRepository {
  /// Whether a persisted session exists right now.
  bool get hasSession;

  /// Emits `true` when a session appears and `false` when it disappears.
  Stream<bool> get signedInChanges;

  /// Native Google sign-in; any provider problem is an [Err] with its reason.
  Future<Result<void>> signInWithGoogle();

  /// `Ok(true)` when allowlisted and this device holds the active session.
  Future<Result<bool>> activateSession();

  /// The signed-in member's profile.
  Future<Result<Member>> currentMember();

  /// Signs out of Google and the backend.
  Future<void> signOut();

  /// The signed-in auth user's id, null when none.
  String? get userId;

  /// The `session_id` claim of the current access token; null when there is
  /// none or it cannot be read.
  String? get sessionId;
}
