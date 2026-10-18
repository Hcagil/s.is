import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/key_directory.dart';
import '../domain/key_engine.dart';

/// The four providers below are null until main wires them; the controller then stays idle.
final keyDirectoryProvider = Provider<KeyDirectory?>((_) => null);
final keyEngineProvider = Provider<KeyEngine?>((_) => null);
final olmPickleStoreProvider = Provider<OlmPickleStore?>((_) => null);
final pickleKeyStoreProvider = Provider<PickleKeyStore?>((_) => null);

/// Where this phone's key publishing stands.
sealed class KeyDirectoryState {
  const KeyDirectoryState();
}

final class KeysIdle extends KeyDirectoryState {
  const KeysIdle();
} // not signed in / nothing to do

final class KeysPublishing extends KeyDirectoryState {
  const KeysPublishing();
}

final class KeysReady extends KeyDirectoryState {
  const KeysReady(this.freeOneTimeKeys);
  final int freeOneTimeKeys;
}

/// Publishing failed; it retries by itself.
final class KeysRetrying extends KeyDirectoryState {
  const KeysRetrying();
}

/// The server has keys for this member but this phone has none it can read (new phone after a reset, wiped store, unreadable pickle). NEVER fixed silently: a new identity changes every contact's security code. Waits for an explicit decision (a later step: restore a backup or reset).
final class KeysIdentityLost extends KeyDirectoryState {
  const KeysIdentityLost();
}

final keyDirectoryControllerProvider =
    NotifierProvider<KeyDirectoryController, KeyDirectoryState>(
      KeyDirectoryController.new,
    );

class KeyDirectoryController extends Notifier<KeyDirectoryState> {
  Timer? _retry;
  int _attempt = 0;
  int _revision = 0;
  bool _busy = false;
  bool _again = false;
  @override
  KeyDirectoryState build() {
    ref.onDispose(() => _retry?.cancel());
    ref.listen(
      sessionControllerProvider,
      (_, next) => _onSession(next.value),
      fireImmediately: false,
    );
    final session = ref.read(sessionControllerProvider).value;
    final user = _userOf(session);
    if (user == null) {
      return const KeysIdle();
    }
    scheduleMicrotask(() => unawaited(refresh()));
    return const KeysPublishing();
  }

  Future<void> refresh() async {
    final userId = _userOf(ref.read(sessionControllerProvider).value);
    if (userId == null) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final rev = _revision;
    try {
      do {
        _again = false;
        await _ensure(userId);
      } while (_again && ref.mounted && rev == _revision);
    } finally {
      _busy = false;
    }
  }

  Future<void> _ensure(String userId) async {
    final rev = _revision;
    bool alive() => ref.mounted && rev == _revision;
    final dir = ref.read(keyDirectoryProvider);
    final engine = ref.read(keyEngineProvider);
    final pickles = ref.read(olmPickleStoreProvider);
    final pickleKeys = ref.read(pickleKeyStoreProvider);
    if (dir == null ||
        engine == null ||
        pickles == null ||
        pickleKeys == null) {
      state = const KeysIdle();
      return;
    }
    final List<int> pickleKey;
    try {
      pickleKey = await pickleKeys.loadOrCreate();
    } catch (_) {
      if (alive()) _scheduleRetry(userId, rev);
      return;
    }
    final saved = await pickles.load();
    if (!alive()) return;
    KeyAccount account;
    if (saved == null) {
      // No pickle: first run, or a lost one. The server decides which; never create silently over an existing server row.
      final st = await dir.status();
      if (!alive()) return;
      switch (st) {
        case Err(failure: DeniedFailure()):
          state = const KeysIdle();
          return;
        case Err():
          _scheduleRetry(userId, rev);
          return;
        case Ok(:final value) when value != null:
          state = const KeysIdentityLost();
          return;
        case Ok():
          break;
      }
      try {
        account = await engine.create();
      } on KeyEngineException {
        _scheduleRetry(userId, rev);
        return;
      }
      account.generateFallbackKey();
      account.generateOneTimeKeys(account.maxOneTimeKeys);
      if (!await _save(account, pickleKey, pickles)) {
        if (alive()) _scheduleRetry(userId, rev);
        return;
      }
    } else {
      try {
        account = await engine.restore(saved, pickleKey);
      } on KeyEngineException {
        if (alive()) state = const KeysIdentityLost();
        return;
      }
    }
    if (!alive()) return;
    // Publish what is not yet published (an empty list just rebinds this session).
    var free = await _publish(dir, account, userId, pickleKey, pickles, rev);
    if (free == null) return; // _publish already set the state (retry or idle)
    final st = await dir.status();
    final fallbackUsed = switch (st) {
      Ok(:final value) => value?.fallbackUsed ?? false,
      Err() => false,
    };
    final room = account.maxOneTimeKeys - account.storedOneTimeKeyCount;
    final low = free < account.maxOneTimeKeys ~/ 2 && room > 0;
    if (low || fallbackUsed) {
      if (low) account.generateOneTimeKeys(room);
      // The engine keeps the previous fallback key itself so late first messages still decrypt; it is never forgotten here.
      if (fallbackUsed) account.generateFallbackKey();
      if (!await _save(account, pickleKey, pickles)) {
        if (alive()) _scheduleRetry(userId, rev);
        return;
      }
      free = await _publish(dir, account, userId, pickleKey, pickles, rev);
      if (free == null) return;
    }
    if (!alive()) return;
    _attempt = 0;
    state = KeysReady(free);
  }

  /// Publishes the account's unpublished keys. On success marks them published and saves the pickle again; returns the free key count. On failure sets the state (Idle when the session was replaced, else retrying) and returns null.
  Future<int?> _publish(
    KeyDirectory dir,
    KeyAccount a,
    String userId,
    List<int> pickleKey,
    OlmPickleStore pickles,
    int rev,
  ) async {
    final r = await dir.publish(
      identityKey: a.identityKey,
      signingKey: a.signingKey,
      deviceSignature: a.sign(
        deviceStatement(userId, a.identityKey, a.signingKey),
      ),
      oneTimeKeys: a.unpublishedOneTimeKeys,
      fallbackKey: a.unpublishedFallbackKey,
    );
    if (!ref.mounted || rev != _revision) return null;
    switch (r) {
      case Ok(:final value):
        a.markPublished();
        await _save(a, pickleKey, pickles); // a failed save only means the next run re-sends the same keys (idempotent)
        return value;
      case Err(failure: DeniedFailure()):
        state = const KeysIdle();
        return null;
      case Err():
        _scheduleRetry(userId, rev);
        return null;
    }
  }

  Future<bool> _save(
    KeyAccount a,
    List<int> key,
    OlmPickleStore pickles,
  ) async {
    try {
      return await pickles.save(a.pickle(key));
    } on KeyEngineException {
      return false;
    }
  }

  /// Claims a chat partner's keys and checks the phone's self-signature; a failed check returns Err(DeviceKeysFailure) and no key (no session may be opened).
  Future<Result<ClaimedKeys?>> claimVerified(String targetUserId) async {
    final dir = ref.read(keyDirectoryProvider);
    final engine = ref.read(keyEngineProvider);
    if (dir == null || engine == null) {
      return const Err(DeniedFailure());
    }
    final r = await dir.claim(targetUserId);
    if (r case Ok(:final value?)) {
      final ok = await engine.verifyDevice(targetUserId, value);
      if (!ok) {
        return const Err(DeviceKeysFailure());
      }
    }
    return r;
  }

  void _onSession(SessionState? s) {
    _retry?.cancel();
    _revision++;
    _attempt = 0;
    final user = _userOf(s);
    if (user == null) {
      state = const KeysIdle();
      return;
    }
    state = const KeysPublishing();
    unawaited(refresh());
  }

  String? _userOf(SessionState? s) {
    if (s is Allowed && s.confirmed) {
      return s.member.userId;
    }
    return null;
  }

  void _scheduleRetry(String userId, int rev) {
    state = const KeysRetrying();
    final delay =
        sessionRetryDelays[[
          _attempt,
          sessionRetryDelays.length - 1,
        ].reduce(math.min)];
    _attempt++;
    _retry = Timer(delay, () {
      if (ref.mounted && rev == _revision) unawaited(refresh());
    });
  }
}
