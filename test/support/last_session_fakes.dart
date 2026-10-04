// Fakes for a cold start from the last confirmed session (0.30.15).
//
// Written from the AuthRepository and LastSessionStore interfaces, not from
// the controller. They behave like the real dependencies where that is
// inconvenient: every call is asynchronous, the server's answer can be held
// in flight until the test gives it, answers can arrive out of order, and an
// error can arrive instead of data.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/last_session.dart';
import 'package:sis/features/auth/domain/member.dart';

/// The marker file, in memory. Every call takes a turn of the event loop, as
/// disk does; [holdClear] keeps a clear() in flight so a test can see what the
/// state already was before the wipe finished.
class MemoryLastSessionStore implements LastSessionStore {
  MemoryLastSessionStore([this.stored]);

  LastSession? stored;
  final saves = <LastSession>[];
  int clears = 0;
  int loads = 0;
  Completer<void>? _clearGate;

  void holdClear() => _clearGate = Completer<void>();
  void releaseClear() {
    _clearGate?.complete();
    _clearGate = null;
  }

  @override
  Future<LastSession?> load() async {
    loads++;
    await Future<void>.delayed(Duration.zero);
    return stored;
  }

  @override
  Future<void> save(LastSession session) async {
    await Future<void>.delayed(Duration.zero);
    saves.add(session);
    stored = session;
  }

  @override
  Future<void> clear() async {
    clears++;
    stored = null;
    final gate = _clearGate;
    if (gate != null) await gate.future;
  }
}

/// One activate_session() call the server has not answered yet.
class PendingCheck {
  final _answer = Completer<Result<bool>>();
  bool get answered => _answer.isCompleted;
  void allow() => _answer.complete(const Ok(true));
  void deny() => _answer.complete(const Ok(false));
  void fail([Failure f = const NetworkFailure('offline', retryable: true)]) =>
      _answer.complete(Err(f));
}

/// Auth with a persisted session whose server checks the test answers one by
/// one, in any order. [userId] and [sessionId] are what the stored token
/// says, readable without the network.
class ColdAuth implements AuthRepository {
  ColdAuth({
    this.session = true,
    this.uid = 'u1',
    this.sid = 'sess-1',
    this.member = const Member(userId: 'u1', displayName: 'Maya', tag: 'maya'),
    this.autoAllow = false,
  });

  bool session;
  String uid;
  String sid;

  /// What currentMember() answers.
  Member member;
  Result<Member>? memberResult;

  /// Answer every check `Ok(true)` at once instead of holding it.
  bool autoAllow;

  /// Every activate_session() call, in the order made.
  final checks = <PendingCheck>[];
  int memberReads = 0;
  int signOuts = 0;
  final changes = StreamController<bool>.broadcast();

  PendingCheck get last => checks.last;

  @override
  bool get hasSession => session;
  @override
  String? get userId => session ? uid : null;
  @override
  String? get sessionId => session ? sid : null;
  @override
  Stream<bool> get signedInChanges => changes.stream;

  @override
  Future<Result<void>> signInWithGoogle() async {
    await Future<void>.delayed(Duration.zero);
    session = true;
    changes.add(true);
    return const Ok(null);
  }

  @override
  Future<Result<bool>> activateSession() {
    final c = PendingCheck();
    checks.add(c);
    if (autoAllow) c.allow();
    return c._answer.future;
  }

  @override
  Future<Result<Member>> currentMember() async {
    memberReads++;
    await Future<void>.delayed(Duration.zero);
    return memberResult ?? Ok(member);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    await Future<void>.delayed(Duration.zero);
    session = false;
    changes.add(false);
  }

  /// The session ends outside the app (expired, revoked elsewhere).
  void endSession() {
    session = false;
    changes.add(false);
  }
}

const markerMe = Member(userId: 'u1', displayName: 'Maya', tag: 'maya');

/// A marker for u1 on sess-1, confirmed [age] ago.
LastSession marker({
  String userId = 'u1',
  String sessionId = 'sess-1',
  bool onboarded = true,
  Duration age = const Duration(hours: 1),
  Member me = markerMe,
}) => LastSession(
  userId: userId,
  sessionId: sessionId,
  me: me,
  onboarded: onboarded,
  confirmedAt: DateTime.now().toUtc().subtract(age),
);
