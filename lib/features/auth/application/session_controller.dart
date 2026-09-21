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

class SessionController extends AsyncNotifier<SessionState> {
  int _revision = 0; // discards results of superseded refreshes

  @override
  Future<SessionState> build() async {
    if (!ref.read(runtimeConfigProvider).isComplete) {
      return const SetupRequired();
    }
    final repo = ref.read(authRepositoryProvider);
    final sub = repo.signedInChanges.listen(
      (signedIn) => unawaited(_refresh(signedIn)),
    );
    ref.onDispose(sub.cancel);
    return _resolve(repo.hasSession);
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
    if (rev == _revision) {
      state = AsyncData(next);
    }
  }

  Future<void> signIn() async {
    state = const AsyncData(SessionLoading());
    final r = await ref.read(authRepositoryProvider).signInWithGoogle();
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
    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(SignedOut());
  }

  Future<void> retry() => _refresh(ref.read(authRepositoryProvider).hasSession);
}
