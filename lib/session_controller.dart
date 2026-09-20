import 'dart:async';

import 'package:flutter/foundation.dart';

enum SessionStatus { setupRequired, signedOut, loading, allowed, denied, error }

/// A sign-in attempt that did not complete, with the reason kept for display.
class SignInFailure implements Exception {
  const SignInFailure({required this.reason, this.userCanceled = false});

  final String reason;
  final bool userCanceled;

  @override
  String toString() => reason;
}

@immutable
class MemberProfile {
  const MemberProfile({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}

class SessionController extends ChangeNotifier {
  SessionController.unconfigured()
    : _status = SessionStatus.setupRequired,
      activateSession = null,
      loadMemberProfiles = null,
      startGoogleSignIn = null,
      performSignOut = null;

  SessionController.connected({
    required bool initiallySignedIn,
    required Stream<bool> signedInChanges,
    required this.activateSession,
    required this.loadMemberProfiles,
    required this.startGoogleSignIn,
    required this.performSignOut,
  }) : _status = SessionStatus.loading,
       assert(activateSession != null),
       assert(loadMemberProfiles != null),
       assert(startGoogleSignIn != null),
       assert(performSignOut != null) {
    _authSubscription = signedInChanges.distinct().listen(_refresh);
    unawaited(_refresh(initiallySignedIn));
  }

  SessionController.failed()
    : _status = SessionStatus.error,
      activateSession = null,
      loadMemberProfiles = null,
      startGoogleSignIn = null,
      performSignOut = null;

  SessionStatus _status;
  final Future<bool> Function()? activateSession;
  final Future<List<MemberProfile>> Function()? loadMemberProfiles;
  final Future<bool> Function()? startGoogleSignIn;
  final Future<void> Function()? performSignOut;
  StreamSubscription<bool>? _authSubscription;
  List<MemberProfile> _members = const [];
  int _revision = 0;
  String? _signInFailure;

  SessionStatus get status => _status;
  List<MemberProfile> get members => _members;
  bool get canRetry => activateSession != null;
  String? get signInFailure => _signInFailure;

  Future<void> signIn() async {
    _signInFailure = null;
    _setStatus(SessionStatus.loading);
    try {
      if (!await startGoogleSignIn!()) {
        _setStatus(SessionStatus.signedOut);
      }
    } on SignInFailure catch (failure) {
      _signInFailure = failure.reason;
      _setStatus(
        failure.userCanceled ? SessionStatus.signedOut : SessionStatus.error,
      );
    } catch (error) {
      _signInFailure = error.toString();
      _setStatus(SessionStatus.error);
    }
  }

  Future<void> signOut() async {
    _revision++;
    _members = const [];
    try {
      await performSignOut?.call();
    } finally {
      _setStatus(SessionStatus.signedOut);
    }
  }

  Future<void> retry() => _refresh(true);

  Future<void> _refresh(bool signedIn) async {
    final revision = ++_revision;
    _members = const [];
    if (!signedIn) {
      _setStatus(SessionStatus.signedOut);
      return;
    }

    _setStatus(SessionStatus.loading);
    try {
      final allowed = await activateSession!();
      if (revision != _revision) return;
      if (!allowed) {
        _setStatus(SessionStatus.denied);
        return;
      }
      _members = await loadMemberProfiles!();
      if (revision == _revision) _setStatus(SessionStatus.allowed);
    } catch (_) {
      if (revision == _revision) _setStatus(SessionStatus.error);
    }
  }

  void _setStatus(SessionStatus value) {
    _status = value;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }
}
