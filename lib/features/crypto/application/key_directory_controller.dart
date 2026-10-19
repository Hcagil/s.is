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

enum _Edit { saved, lost, failed }

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
    if (saved == null) {
      // No pickle: first run, a lost one, or a new sign-in. A server row bound to this same session means the key is lost; never create silently over it.
      final st = await dir.status();
      if (!alive()) return;
      switch (st) {
        case Err(failure: DeniedFailure()):
          state = const KeysIdle();
          return;
        case Err():
          _scheduleRetry(userId, rev);
          return;
        case Ok(:final value) when value != null && value.sameSession:
          state = const KeysIdentityLost();
          return;
        case Ok():
          break;
      }
      final e = await _edit(
        pickles,
        engine,
        pickleKey,
        onNew: (a) {
          a.generateFallbackKey();
          a.generateOneTimeKeys(a.maxOneTimeKeys);
        },
      );
      if (!_editOk(e, userId, rev)) return;
    }
    if (!alive()) return;
    // Publish what is not yet published (an empty list just rebinds this session).
    var free = await _publish(dir, engine, userId, pickleKey, pickles, rev);
    if (free == null) return; // _publish already set the state (retry or idle)
    final st = await dir.status();
    final fallbackUsed = switch (st) {
      Ok(:final value) => value?.fallbackUsed ?? false,
      Err() => false,
    };
    final freeNow = free;
    var gen = false;
    final e2 = await _edit(
      pickles,
      engine,
      pickleKey,
      change: (a) {
        final room = a.maxOneTimeKeys - a.storedOneTimeKeyCount;
        if (freeNow < a.maxOneTimeKeys ~/ 2 && room > 0) {
          a.generateOneTimeKeys(room);
          gen = true;
        }
        // The engine keeps the previous fallback key itself so late first messages still decrypt; it is never forgotten here.
        if (fallbackUsed) {
          a.generateFallbackKey();
          gen = true;
        }
        return gen;
      },
    );
    if (!_editOk(e2, userId, rev)) return;
    if (gen) {
      free = await _publish(dir, engine, userId, pickleKey, pickles, rev);
      if (free == null) return;
    }
    if (!alive()) return;
    _attempt = 0;
    state = KeysReady(free);
  }

  /// True when the edit saved. Otherwise sets the state (identity lost, or retrying) and returns false.
  bool _editOk(_Edit e, String userId, int rev) {
    if (e == _Edit.saved) return true;
    if (!ref.mounted || rev != _revision) return false;
    if (e == _Edit.lost) {
      state = const KeysIdentityLost();
    } else {
      _scheduleRetry(userId, rev);
    }
    return false;
  }

  /// Publishes the account's unpublished keys. The account is read in one transaction, the network call holds no account, and marking published is a second transaction on a fresh read. Returns the free key count. On failure sets the state (Idle when the session was replaced, else retrying) and returns null.
  Future<int?> _publish(
    KeyDirectory dir,
    KeyEngine engine,
    String userId,
    List<int> pickleKey,
    OlmPickleStore pickles,
    int rev,
  ) async {
    late String identityKey, signingKey, signature;
    late List<String> otks;
    String? fallback;
    final snap = await _edit(
      pickles,
      engine,
      pickleKey,
      change: (a) {
        identityKey = a.identityKey;
        signingKey = a.signingKey;
        signature = a.sign(
          deviceStatement(userId, a.identityKey, a.signingKey),
        );
        otks = a.unpublishedOneTimeKeys;
        fallback = a.unpublishedFallbackKey;
        return false; // read only, nothing saved
      },
    );
    if (!_editOk(snap, userId, rev)) return null;
    final r = await dir.publish(
      identityKey: identityKey,
      signingKey: signingKey,
      deviceSignature: signature,
      oneTimeKeys: otks,
      fallbackKey: fallback,
    );
    if (!ref.mounted || rev != _revision) return null;
    switch (r) {
      case Ok(:final value):
        // a failed save only means the next run re-sends the same keys (idempotent)
        await _edit(
          pickles,
          engine,
          pickleKey,
          change: (a) {
            a.markPublished();
            return true;
          },
        );
        return value;
      case Err(failure: DeniedFailure()):
        state = const KeysIdle();
        return null;
      case Err():
        _scheduleRetry(userId, rev);
        return null;
    }
  }

  /// The ONLY place the account is changed: read, change and save inside one store transaction. [onNew] makes a first account when none is saved; [change] edits a saved one and returns whether to save it.
  Future<_Edit> _edit(
    OlmPickleStore pickles,
    KeyEngine engine,
    List<int> pickleKey, {
    void Function(KeyAccount)? onNew,
    bool Function(KeyAccount)? change,
  }) async {
    var r = _Edit.failed;
    final ok = await pickles.update((cur) async {
      final KeyAccount a;
      if (cur == null) {
        if (onNew == null) {
          r = _Edit.lost;
          return null;
        }
        try {
          a = await engine.create();
        } on KeyEngineException {
          return null;
        }
        onNew(a);
      } else {
        try {
          a = await engine.restore(cur, pickleKey);
        } on KeyEngineException {
          r = _Edit.lost;
          return null;
        }
        if (change != null && !change(a)) {
          r = _Edit.saved;
          return null;
        }
      }
      try {
        final pickle = a.pickle(pickleKey);
        r = _Edit.saved;
        return pickle;
      } on KeyEngineException {
        return null;
      }
    });
    return ok ? r : _Edit.failed;
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
