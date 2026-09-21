// Hand-written fakes shared by controller and widget tests.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/update/domain/update_repository.dart';

class FakeAuth implements AuthRepository {
  FakeAuth({
    this.session = false,
    this.allowed = true,
    this.signInResult = const Ok(null),
  });
  bool session;
  bool allowed;
  Result<void> signInResult;
  final changes = StreamController<bool>.broadcast();
  @override
  bool get hasSession => session;
  @override
  Stream<bool> get signedInChanges => changes.stream;
  @override
  Future<Result<void>> signInWithGoogle() async {
    if (signInResult is Ok) {
      session = true;
      changes.add(true);
    }
    return signInResult;
  }

  @override
  Future<Result<bool>> activateSession() async => Ok(allowed);
  @override
  Future<Result<Member>> currentMember() async =>
      const Ok(Member(userId: 'u1', displayName: 'Maya'));
  @override
  Future<void> signOut() async {
    session = false;
    changes.add(false);
  }
}

class FakeUpdate implements UpdateRepository {
  FakeUpdate({
    this.installed = 105,
    this.min = const Ok(1),
    this.play = const Ok(null),
  });

  int installed;
  Result<int> min;
  Result<int?> play;
  final calls = <String>[];
  bool failFlexible = false;
  bool failImmediate = false;

  @override
  Future<int> installedBuild() async => installed;
  @override
  Future<Result<int>> minSupportedBuild() async => min;
  @override
  Future<Result<int?>> availablePlayBuild() async => play;
  @override
  Future<void> startFlexibleUpdate() async {
    calls.add('flexible');
    if (failFlexible) throw StateError('declined');
  }

  @override
  Future<void> completeFlexibleUpdate() async => calls.add('complete');
  @override
  Future<void> startImmediateUpdate() async {
    calls.add('immediate');
    if (failImmediate) throw StateError('unavailable');
  }

  @override
  Future<void> openStoreListing() async => calls.add('store');
}
