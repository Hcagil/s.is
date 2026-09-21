import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../../core/runtime_config.dart';
import '../domain/auth_repository.dart';
import '../domain/session_state.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final runtimeConfigProvider = Provider<RuntimeConfig>(
  (_) => RuntimeConfig.fromEnvironment(),
);
final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, SessionState>(
      SessionController.new,
    );

/// Session state machine; every failure carries a reason for the screen.
class SessionController extends AsyncNotifier<SessionState> {
  int _revision = 0; // discards results of superseded refreshes
  bool? _lastSignedIn; // the auth stream replays the current session

  @override
  Future<SessionState> build() async {
    if (!ref.read(runtimeConfigProvider).isComplete) {
      return const SetupRequired();
    }
    final repo = ref.read(authRepositoryProvider);
    _lastSignedIn = repo.hasSession;
    final sub = repo.signedInChanges.listen((signedIn) {
      if (signedIn == _lastSignedIn) return;
      _lastSignedIn = signedIn;
      unawaited(_refresh(signedIn));
    });
    ref.onDispose(sub.cancel);
    final rev = ++_revision;
    final next = await _resolve(repo.hasSession);
    if (rev != _revision) return state.value ?? next;
    return next;
  }

  Future<SessionState> _resolve(bool signedIn) async {
    final repo = ref.read(authRepositoryProvider);
    if (!signedIn) return const SignedOut();
    switch (await repo.activateSession()) {
      case Err(:final failure):
        return SessionError(failure.message);
      case Ok(value: false):
        return const Denied();
      case Ok(value: true):
        return switch (await repo.currentMember()) {
          Ok(:final value) => Allowed(value),
          Err(:final failure) => SessionError(failure.message),
        };
    }
  }

  Future<void> _refresh(bool signedIn) async {
    final rev = ++_revision;
    state = const AsyncData(SessionLoading());
    final next = await _resolve(signedIn);
    if (!ref.mounted || rev != _revision) return;
    state = AsyncData(next);
  }

  Future<void> signIn() async {
    state = const AsyncData(SessionLoading());
    final r = await ref.read(authRepositoryProvider).signInWithGoogle();
    if (!ref.mounted) return;
    if (r is Err) {
      final f = r.failure;
      state = AsyncData(
        f is ProviderFailure && f.userCanceled
            ? SignedOut(reason: f.message)
            : SessionError(f.message),
      );
    }
    // On Ok the signedInChanges stream drives _refresh(true).
  }

  Future<void> signOut() async {
    _revision++;
    _lastSignedIn = false;
    try {
      await ref.read(authRepositoryProvider).signOut();
    } finally {
      if (ref.mounted) state = const AsyncData(SignedOut());
    }
  }

  Future<void> retry() => _refresh(ref.read(authRepositoryProvider).hasSession);
}
