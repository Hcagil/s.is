import 'member.dart';

/// The state of the current session, as rendered by the session gate.
sealed class SessionState {
  const SessionState();
}

/// Runtime configuration is incomplete; nothing can connect.
final class SetupRequired extends SessionState {
  const SetupRequired();
}

/// No session; [reason] explains why the last sign-in did not complete.
final class SignedOut extends SessionState {
  const SignedOut({this.reason});

  final String? reason;
}

/// A session is being established or refreshed.
final class SessionLoading extends SessionState {
  const SessionLoading();
}

/// Allowlisted and holding the active device session.
final class Allowed extends SessionState {
  const Allowed(this.member, {this.confirmed = true, this.onboarded = false});

  final Member member;

  /// True once the server has answered "allowed" in this run; false while the
  /// state comes from the stored last-session marker and the answer is pending.
  final bool confirmed;

  /// The marker said the member finished the first-run screen, so the gate may
  /// show Home while the profile loads.
  final bool onboarded;
}

/// Signed in with Google but not on the allowlist.
final class Denied extends SessionState {
  const Denied();
}

/// Something failed; [reason] is always shown to the user.
final class SessionError extends SessionState {
  const SessionError(this.reason);

  final String reason;
}
