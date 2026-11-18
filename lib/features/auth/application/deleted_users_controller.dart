import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import 'account_deletion_controller.dart';

/// Which account ids the server says no longer exist. Ids are asked once per run of the app; a failed ask is retried at most once a minute per id.
class DeletedUsersController extends Notifier<Set<String>> {
  final _answered = <String>{};
  final _inFlight = <String>{};
  final _retryAt = <String, DateTime>{};

  @override
  Set<String> build() => const {};

  /// Of [ids], the ones whose stored messages must stay on this phone: accounts reported deleted, and ids with no server answer yet (a failed or missing answer never deletes anything).
  Future<Set<String>> keepable(Set<String> ids) async {
    try {
      await check(ids);
    } catch (_) {
      return ids;
    }
    return {
      for (final id in ids)
        if (state.contains(id) || !_answered.contains(id)) id,
    };
  }

  /// Asks the server about [ids] not asked before (200 per call, done by the repository); adds the ones reported missing to the state.
  Future<void> check(Iterable<String> ids) async {
    final now = clock.now();
    final fresh = ids
        .where(
          (id) =>
              !_answered.contains(id) &&
              !_inFlight.contains(id) &&
              (_retryAt[id] == null || !now.isBefore(_retryAt[id]!)),
        )
        .toSet();
    if (fresh.isEmpty) return;
    _inFlight.addAll(fresh);
    Result<Set<String>>? r;
    try {
      r = await ref
          .read(accountDeletionRepositoryProvider)
          .missingUsers(fresh.toList());
    } catch (_) {
      // A missing repository or a thrown call is a failed ask: the label check never breaks a screen.
    }
    _inFlight.removeAll(fresh);
    if (!ref.mounted) return;
    switch (r) {
      case Ok(:final value):
        _answered.addAll(fresh);
        fresh.forEach(_retryAt.remove);
        if (value.isNotEmpty) state = {...state, ...value};
      case Err() || null:
        final retry = clock.now().add(const Duration(minutes: 1));
        for (final id in fresh) {
          _retryAt[id] = retry;
        }
    }
  }
}

final deletedUsersControllerProvider =
    NotifierProvider<DeletedUsersController, Set<String>>(
      DeletedUsersController.new,
    );
