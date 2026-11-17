import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import 'account_deletion_controller.dart';

/// Which account ids the server says no longer exist. Ids are asked once per run of the app (the answer cannot change back); a failed ask is retried the next time.
class DeletedUsersController extends Notifier<Set<String>> {
  final _asked = <String>{};

  @override
  Set<String> build() => const {};

  /// Asks the server about [ids] not asked before (200 per call, done by the repository); adds the ones reported missing to the state.
  Future<void> check(Iterable<String> ids) async {
    final fresh = ids.where((id) => !_asked.contains(id)).toSet();
    if (fresh.isEmpty) return;
    _asked.addAll(fresh);
    final r = await ref
        .read(accountDeletionRepositoryProvider)
        .missingUsers(fresh.toList());
    if (!ref.mounted) return;
    switch (r) {
      case Ok(:final value):
        if (value.isNotEmpty) state = {...state, ...value};
      case Err():
        _asked.removeAll(fresh);
    }
  }
}

final deletedUsersControllerProvider =
    NotifierProvider<DeletedUsersController, Set<String>>(
      DeletedUsersController.new,
    );
