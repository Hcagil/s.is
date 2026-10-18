// Fakes for the key directory (Private Chats step 3), written from the
// interfaces in lib/features/crypto/domain, not from the implementation.
// They behave like the real parts where it matters to the controller:
// - an account's pickle is a snapshot: restoring it brings back exactly the
//   keys that were unpublished when it was taken (as vodozemac does);
// - a pickle read with another key, or a garbled one, throws
//   KeyEngineException;
// - the directory answers after a hop (or when a test completes it), and can
//   answer with an error instead of data.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

/// Every call any fake saw, in order: 'status', 'create', 'restore',
/// 'gen:N', 'fallback', 'mark', 'save', 'publish:N' (+ ':fb' with a fallback).
typedef KeyLog = List<String>;

/// A session the test drives: starts as [initial], [set] moves it.
class DrivenSession extends SessionController {
  DrivenSession(this.initial);
  final SessionState initial;

  @override
  Future<SessionState> build() async => initial;

  void set(SessionState s) => state = AsyncData(s);
}

class FakeAccount implements KeyAccount {
  FakeAccount(this._log, this.id, {this.storedOneTimeKeyCount = 0});
  final KeyLog _log;
  final int id;
  final List<String> _unpublished = [];
  String? _fallback;
  int _serial = 0;

  @override
  String get identityKey => 'IDENTITY-$id';
  @override
  String get signingKey => 'SIGNING-$id';
  @override
  int get maxOneTimeKeys => 50;
  @override
  int storedOneTimeKeyCount;

  @override
  void generateOneTimeKeys(int count) {
    _log.add('gen:$count');
    for (var i = 0; i < count; i++) {
      _unpublished.add('otk-$id-${_serial++}');
    }
    storedOneTimeKeyCount += count;
  }

  @override
  void generateFallbackKey() {
    _log.add('fallback');
    _fallback = 'fb-$id-${_serial++}';
  }

  @override
  List<String> get unpublishedOneTimeKeys => List.of(_unpublished);
  @override
  String? get unpublishedFallbackKey => _fallback;

  @override
  void markPublished() {
    _log.add('mark');
    _unpublished.clear();
    _fallback = null;
  }

  @override
  String sign(String message) => 'sig[$id]($message)';

  @override
  String pickle(List<int> key) {
    if (key.length != 32) throw const KeyEngineException();
    return FakeEngine.snapshot(this, key);
  }

  FakeAccount _copy([KeyLog? log]) =>
      FakeAccount(log ?? _log, id, storedOneTimeKeyCount: storedOneTimeKeyCount)
        .._unpublished.addAll(_unpublished)
        .._fallback = _fallback
        .._serial = _serial;
}

class FakeEngine implements KeyEngine {
  FakeEngine(this._log);
  final KeyLog _log;
  int created = 0;

  /// Answer for verifyDevice; calls are recorded in [verified].
  bool verifyAnswer = true;
  final verified = <(String, ClaimedKeys)>[];

  static final _pickles = <String, (FakeAccount, String)>{};
  static int _next = 0;

  /// The pickle text: a handle to a copy of [a] as it is now.
  static String snapshot(FakeAccount a, List<int> key) {
    final p = 'PICKLE-SECRET-${_next++}';
    _pickles[p] = (a._copy(), key.join(','));
    return p;
  }

  /// The account a pickle holds, without logging (for assertions).
  static FakeAccount? peek(String? pickle) => _pickles[pickle]?.$1;

  @override
  Future<KeyAccount> create() async {
    _log.add('create');
    return FakeAccount(_log, ++created);
  }

  @override
  Future<KeyAccount> restore(String pickle, List<int> key) async {
    _log.add('restore');
    final hit = _pickles[pickle];
    if (hit == null || hit.$2 != key.join(',')) {
      throw const KeyEngineException();
    }
    return hit.$1._copy(_log);
  }

  @override
  Future<bool> verifyDevice(String userId, ClaimedKeys keys) async {
    verified.add((userId, keys));
    return verifyAnswer;
  }
}

typedef PublishCall = ({
  String identityKey,
  String signingKey,
  String deviceSignature,
  List<String> oneTimeKeys,
  String? fallbackKey,
});

class FakeKeyDirectory implements KeyDirectory {
  FakeKeyDirectory(this._log);
  final KeyLog _log;

  /// Answers in order; when empty, [status] is Ok(null) and [publish] is
  /// Ok(free count the server would hold).
  final statusAnswers = <FutureOr<Result<PublishedStatus?>>>[];
  final publishAnswers = <FutureOr<Result<int>>>[];
  Result<ClaimedKeys?> claimAnswer = const Ok(null);

  final publishes = <PublishCall>[];
  final claims = <String>[];
  int statusCalls = 0;
  final _free = <String>{};

  /// The server already holds [n] free keys (keep it equal to any status
  /// row the test answers with: one server, one count).
  void seedFree(int n) =>
      _free.addAll([for (var i = 0; i < n; i++) 'server-$i']);

  @override
  Future<Result<PublishedStatus?>> status() async {
    statusCalls++;
    _log.add('status');
    await Future<void>.value(); // an async hop, as a real call has
    if (statusAnswers.isNotEmpty) return statusAnswers.removeAt(0);
    return const Ok(null);
  }

  @override
  Future<Result<int>> publish({
    required String identityKey,
    required String signingKey,
    required String deviceSignature,
    required List<String> oneTimeKeys,
    String? fallbackKey,
  }) async {
    publishes.add((
      identityKey: identityKey,
      signingKey: signingKey,
      deviceSignature: deviceSignature,
      oneTimeKeys: List.of(oneTimeKeys),
      fallbackKey: fallbackKey,
    ));
    _log.add(
      'publish:${oneTimeKeys.length}${fallbackKey == null ? '' : ':fb'}',
    );
    await Future<void>.value(); // an async hop, as a real call has
    if (publishAnswers.isNotEmpty) return publishAnswers.removeAt(0);
    _free.addAll(oneTimeKeys);
    return Ok(_free.length);
  }

  @override
  Future<Result<ClaimedKeys?>> claim(String userId) async {
    claims.add(userId);
    await Future<void>.value(); // an async hop, as a real call has
    return claimAnswer;
  }
}

class FakePickleStore implements OlmPickleStore {
  FakePickleStore(this._log, [this.saved]);
  final KeyLog _log;
  String? saved;

  /// How many of the next saves fail (return false, nothing stored).
  int failNext = 0;
  final savedHistory = <String>[];

  @override
  Future<String?> load() async => saved;

  @override
  Future<bool> save(String pickle) async {
    _log.add('save');
    if (failNext > 0) {
      failNext--;
      return false;
    }
    saved = pickle;
    savedHistory.add(pickle);
    return true;
  }
}

class FakePickleKeys implements PickleKeyStore {
  static final key = List<int>.filled(32, 7);
  @override
  Future<List<int>> loadOrCreate() async => List.of(key);
  @override
  Future<void> delete() async {}
}

PublishedStatus serverRow({
  int free = 50,
  bool hasFallback = true,
  bool fallbackUsed = false,
  int id = 1,
}) => PublishedStatus(
  identityKey: 'IDENTITY-$id',
  signingKey: 'SIGNING-$id',
  oneTimeKeys: free,
  hasFallback: hasFallback,
  fallbackUsed: fallbackUsed,
);
