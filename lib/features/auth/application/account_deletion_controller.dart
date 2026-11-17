import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../domain/account_deletion_repository.dart';

final accountDeletionRepositoryProvider = Provider<AccountDeletionRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// Runs the delete-my-account request; the state is true while it runs, so the screen can show a spinner and ignore a second tap.
class AccountDeletionController extends Notifier<bool> {
  @override
  bool build() => false;

  /// The server is asked to remove the account in 29 days; see [AccountDeletionRepository.requestDeletion].
  Future<Result<DateTime>> request() async {
    // a second tap is a silent no-op: userCanceled hides the message
    if (state) return const Err(ProviderFailure('', userCanceled: true));
    state = true;
    try {
      return await ref
          .read(accountDeletionRepositoryProvider)
          .requestDeletion();
    } finally {
      if (ref.mounted) state = false;
    }
  }
}

final accountDeletionControllerProvider =
    NotifierProvider<AccountDeletionController, bool>(
      AccountDeletionController.new,
    );
