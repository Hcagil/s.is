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
  const Allowed(this.member);

  final Member member;
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
