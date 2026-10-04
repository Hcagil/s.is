import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../../core/runtime_config.dart';
import '../domain/auth_repository.dart';
import '../domain/last_session.dart';
import '../domain/member.dart';
import '../domain/session_state.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final runtimeConfigProvider = Provider<RuntimeConfig>(
  (_) => RuntimeConfig.fromEnvironment(),
);
final lastSessionStoreProvider = Provider<LastSessionStore>(
  (_) => throw UnimplementedError('override in main'),
);
final sessionControllerProvider =
    AsyncNotifierProvider<SessionController, SessionState>(
      SessionController.new,
    );

/// True while the stored session could not be confirmed because the server
/// did not answer; drives the small notice on Home.
final sessionCheckFailedProvider = NotifierProvider<SessionCheckFailed, bool>(
  SessionCheckFailed.new,
);

class SessionCheckFailed extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool failed) => state = failed;
}

/// The retry ladder for an unconfirmed session: 2 s, 4 s ... up to 60 s; the
/// last delay repeats until the server answers.
const sessionRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 32),
  Duration(seconds: 60),
];

/// Who is signed in: the allowed member's user id, or null.
///
/// Every provider that holds one account's data watches this, so switching
/// account rebuilds it for the new one instead of showing the last account's
/// members, conversations or profile until the app restarts.
///
/// Only a settled answer counts: while the session is (re)checking, the last
/// known account stands. A recheck of the same member must not look like a
/// sign-out -- that would close the open conversation and reload everything.
///
/// A SessionLoading value counts as not settled.
final currentUserIdProvider = NotifierProvider<CurrentUserId, String?>(
  CurrentUserId.new,
);

class CurrentUserId extends Notifier<String?> {
  static String? _idOf(AsyncValue<SessionState> session) =>
      switch (session.value) {
        Allowed(:final member) => member.userId,
        _ => null,
      };

  @override
  String? build() {
    ref.listen(sessionControllerProvider, (_, next) {
      if (next.isLoading || next.value is SessionLoading) return;
      final id = _idOf(next);
      if (id != state) state = id;
    });
    final now = ref.read(sessionControllerProvider);
    return now.isLoading || now.value is SessionLoading ? null : _idOf(now);
  }
}

/// Session state machine; every failure carries a reason for the screen.
///
/// Cold start: when the stored "last confirmed session" marker is for this very
/// account and session, recent, and the member had finished the first-run
/// screen, the state is [Allowed] with `confirmed: false` at once, from the
/// file, and the server is asked behind it. Anything else takes the gated path
/// (wait for the server). The server's answer is the only thing that confirms
/// or locks; RLS stays the authority for every read and write meanwhile.
class SessionController extends AsyncNotifier<SessionState> {
  int _revision = 0; // discards results of superseded refreshes
  bool? _lastSignedIn; // the auth stream replays the current session
  LastSession? _marker; // what the file holds for the current account
  Timer? _retryTimer;
  int _attempt = 0;

  @override
  Future<SessionState> build() async {
    if (!ref.read(runtimeConfigProvider).isComplete) {
      return const SetupRequired();
    }
    final repo = ref.read(authRepositoryProvider);
    _lastSignedIn = repo.hasSession;
    final sub = repo.signedInChanges.listen(
      (signedIn) {
        if (signedIn == _lastSignedIn) return;
        _lastSignedIn = signedIn;
        unawaited(_refresh(signedIn));
      },
      // Offline, a failed token refresh is replayed on this stream as an
      // error. It says nothing about who is signed in: the session is kept,
      // and the server check behind the stored list retries by itself.
      onError: (Object _) {},
    );
    ref.onDispose(sub.cancel);
    ref.onDispose(() => _retryTimer?.cancel());
    final rev = ++_revision;
    if (repo.hasSession) {
      final fast = await _fromMarker(repo);
      if (rev != _revision) {
        return state.value ?? fast ?? const SessionLoading();
      }
      if (fast != null) {
        unawaited(_confirm(repo, fast));
        return fast;
      }
    }
    final next = await _resolve(repo.hasSession);
    if (rev != _revision) return state.value ?? next;
    unawaited(_settle(repo, next));
    return next;
  }

  // The store provider throws when it is not overridden (most tests), and a
  // marker is a convenience, never a source of truth: every access is guarded.
  Future<LastSession?> _loadMarker() async {
    try {
      return await ref.read(lastSessionStoreProvider).load();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveMarker(LastSession marker) async {
    try {
      await ref.read(lastSessionStoreProvider).save(marker);
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _wipeMarker() async {
    _marker = null;
    try {
      await ref.read(lastSessionStoreProvider).clear();
    } catch (_) {
      // Best-effort.
    }
  }

  /// The optimistic state, or null when the gated path must run instead.
  Future<Allowed?> _fromMarker(AuthRepository repo) async {
    final marker = await _loadMarker();
    if (marker == null) return null;
    final uid = repo.userId;
    final sid = repo.sessionId;
    if (uid == null) return null;
    if (marker.userId != uid) {
      // Another account signed in: the old account's marker is gone for good.
      await _wipeMarker();
      return null;
    }
    // A new session id or an old marker keeps the file (the next confirmation
    // overwrites it) but never stands in for the server.
    if (sid == null || marker.sessionId != sid || !marker.onboarded) {
      return null;
    }
    final now = DateTime.now();
    if (marker.confirmedAt.isAfter(now) ||
        now.difference(marker.confirmedAt) > lastSessionMaxAge) {
      return null;
    }
    _marker = marker;
    return Allowed(marker.me, confirmed: false, onboarded: true);
  }

  /// The gated path: wait for the server.
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

  /// What the file holds follows the settled gated answer.
  Future<void> _settle(AuthRepository repo, SessionState s) async {
    if (s is Allowed) {
      await _writeConfirmed(repo, s.member);
    } else if (s is Denied || s is SignedOut) {
      await _wipeMarker();
    }
  }

  /// Written only when the server has just said yes: [LastSession.confirmedAt]
  /// moves on nothing else.
  Future<void> _writeConfirmed(AuthRepository repo, Member me) async {
    final uid = repo.userId;
    final sid = repo.sessionId;
    if (uid == null || sid == null) return;
    final old = _marker;
    final same = old != null && old.userId == uid && old.sessionId == sid;
    final next = LastSession(
      userId: uid,
      sessionId: sid,
      me: me,
      onboarded: same && old.onboarded,
      confirmedAt: DateTime.now(),
    );
    _marker = next;
    await _saveMarker(next);
  }

  /// Asks the server behind the stored list. Never confirms and never clears
  /// on a failure: it keeps the list, shows the notice and tries again on the
  /// [sessionRetryDelays] ladder.
  Future<void> _confirm(AuthRepository repo, Allowed from) async {
    _retryTimer?.cancel();
    final rev = ++_revision;
    final answer = await repo.activateSession();
    if (!ref.mounted || rev != _revision) return;
    final failed = ref.read(sessionCheckFailedProvider.notifier);
    switch (answer) {
      case Err():
        failed.set(true);
        final i = _attempt < sessionRetryDelays.length
            ? _attempt
            : sessionRetryDelays.length - 1;
        _attempt++;
        _retryTimer = Timer(sessionRetryDelays[i], () {
          if (ref.mounted && rev == _revision) unawaited(_confirm(repo, from));
        });
      case Ok(value: false):
        // Assigned before any await: the lock lands in this very frame.
        failed.set(false);
        state = const AsyncData(Denied());
        _attempt = 0;
        await _wipeMarker();
      case Ok(value: true):
        _attempt = 0;
        failed.set(false);
        state = AsyncData(Allowed(from.member, onboarded: from.onboarded));
        await _writeConfirmed(repo, from.member);
        // The profile refresh runs behind: its failure never undoes this.
        final profile = await repo.currentMember();
        if (!ref.mounted || rev != _revision) return;
        if (profile case Ok(:final value)) {
          state = AsyncData(Allowed(value, onboarded: from.onboarded));
          await _writeConfirmed(repo, value);
        }
    }
  }

  /// Asks again at once if the session is still unconfirmed; called when the
  /// app returns to the foreground.
  void recheck() {
    final s = state.value;
    if (s is Allowed && !s.confirmed && ref.mounted) {
      _attempt = 0;
      unawaited(_confirm(ref.read(authRepositoryProvider), s));
    }
  }

  /// The profile says the first-run screen is done: the marker may now stand
  /// in for the gate on the next cold start. [LastSession.confirmedAt] is not
  /// touched.
  void markOnboarded() {
    final m = _marker;
    if (m == null || m.onboarded) return;
    final next = m.copyWith(onboarded: true);
    _marker = next;
    unawaited(_saveMarker(next));
  }

  Future<void> _refresh(bool signedIn) async {
    final rev = ++_revision;
    _retryTimer?.cancel();
    final repo = ref.read(authRepositoryProvider);
    if (!signedIn) {
      // Expiry or sign-out elsewhere locks at once, with no loading flash.
      ref.read(sessionCheckFailedProvider.notifier).set(false);
      state = const AsyncData(SignedOut());
      await _wipeMarker();
      return;
    }
    state = const AsyncData(SessionLoading());
    final next = await _resolve(signedIn);
    if (!ref.mounted || rev != _revision) return;
    state = AsyncData(next);
    unawaited(_settle(repo, next));
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
    _retryTimer?.cancel();
    try {
      await ref.read(authRepositoryProvider).signOut();
    } finally {
      if (ref.mounted) {
        state = const AsyncData(SignedOut());
        ref.read(sessionCheckFailedProvider.notifier).set(false);
      }
      unawaited(_wipeMarker());
    }
  }

  Future<void> retry() => _refresh(ref.read(authRepositoryProvider).hasSession);
}
