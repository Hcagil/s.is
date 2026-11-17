import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/account_deletion_controller.dart';
import 'package:sis/features/auth/application/deleted_users_controller.dart';
import 'package:sis/features/auth/domain/account_deletion_repository.dart';

class _Repo implements AccountDeletionRepository {
  _Repo(this.onAsk);
  final Future<Result<Set<String>>> Function(List<String>) onAsk;
  final calls = <List<String>>[];

  @override
  Future<Result<DateTime>> requestDeletion() => throw UnimplementedError();

  @override
  Future<Result<Set<String>>> missingUsers(List<String> ids) {
    calls.add(List.of(ids));
    return onAsk(ids);
  }
}

ProviderContainer _mount(_Repo r) {
  final c = ProviderContainer(
    overrides: [accountDeletionRepositoryProvider.overrideWithValue(r)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test(
    'check puts the ids the server reports missing into the state',
    () async {
      final r = _Repo((ids) async => Ok({'vic'}));
      final c = _mount(r);
      final n = c.read(deletedUsersControllerProvider.notifier);
      await n.check(['vic', 'uma']);
      expect(c.read(deletedUsersControllerProvider), unorderedEquals({'vic'}));
      expect(r.calls.length, 1);
      expect(r.calls.single, unorderedEquals(['vic', 'uma']));
    },
  );

  test('an id is asked once per run', () async {
    final r = _Repo((ids) async => Ok({'vic'}));
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    await n.check(['vic', 'uma']);
    await n.check(['vic', 'uma']);
    expect(r.calls.length, 1);
    expect(c.read(deletedUsersControllerProvider), unorderedEquals({'vic'}));
  });

  test('only the new id is asked later', () async {
    final r = _Repo((ids) async => Ok({'vic'}));
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    await n.check(['vic', 'uma']);
    await n.check(['vic', 'wes']);
    expect(r.calls.length, 2);
    expect(r.calls[1], unorderedEquals(['wes']));
  });

  test('a failed ask is not repeated within a minute, and nothing is marked missing', () async {
    final r = _Repo((ids) async => Err(ProviderFailure('offline')));
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    await n.check(['x']);
    await n.check(['x']);
    expect(r.calls.length, 1);
    expect(c.read(deletedUsersControllerProvider), isEmpty);
  });

  test('an id already in flight is not asked again', () async {
    final completer = Completer<Result<Set<String>>>();
    final r = _Repo((ids) async => completer.future);
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    final f1 = n.check(['x']);
    final f2 = n.check(['x']);
    completer.complete(Ok({'x'}));
    await Future.wait([f1, f2]);
    expect(r.calls.length, 1);
    expect(c.read(deletedUsersControllerProvider), unorderedEquals({'x'}));
  });

  test('keepable keeps a deleted id and drops an alive one', () async {
    final r = _Repo((ids) async => Ok({'vic'}));
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    expect(await n.keepable({'vic', 'uma'}), unorderedEquals({'vic'}));
  });

  test('keepable keeps an id whose ask failed', () async {
    final r = _Repo((ids) async => Err(ProviderFailure('offline')));
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    expect(await n.keepable({'a', 'b'}), unorderedEquals({'a', 'b'}));
  });

  test('keepable keeps everything when the repository is not wired', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(deletedUsersControllerProvider.notifier);
    expect(await n.keepable({'a', 'b'}), unorderedEquals({'a', 'b'}));
  });

  test('keepable keeps an id whose ask is still in flight', () async {
    final completer = Completer<Result<Set<String>>>();
    final r = _Repo((ids) async => completer.future);
    final c = _mount(r);
    final n = c.read(deletedUsersControllerProvider.notifier);
    final f = n.check(['x']);
    final k = n.keepable({'x'});
    completer.complete(Ok(<String>{}));
    await f;
    expect(await k, unorderedEquals({'x'}));
    expect(r.calls.length, 1);
  });

  test(
    'keepable asks the server once and an alive answer is remembered',
    () async {
      final r = _Repo((ids) async => Ok(<String>{}));
      final c = _mount(r);
      final n = c.read(deletedUsersControllerProvider.notifier);
      expect(await n.keepable({'u'}), isEmpty);
      expect(await n.keepable({'u'}), isEmpty);
      expect(r.calls.length, 1);
    },
  );

  test('a failed ask is not repeated at 59 s but is asked again at 61 s', () async {
    var now = DateTime(2026, 1, 1, 12);
    await withClock(Clock(() => now), () async {
      final r = _Repo((ids) async => Err(ProviderFailure('offline')));
      final c = _mount(r);
      final n = c.read(deletedUsersControllerProvider.notifier);
      await n.check(['x']);
      expect(r.calls.length, 1);
      now = now.add(const Duration(seconds: 59));
      await n.check(['x']);
      expect(r.calls.length, 1);
      now = now.add(const Duration(seconds: 2));
      await n.check(['x']);
      expect(r.calls.length, 2);
      expect(c.read(deletedUsersControllerProvider), isEmpty);
    });
  });
}
