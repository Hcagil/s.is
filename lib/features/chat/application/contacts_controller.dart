part of 'chat_controllers.dart';

/// "Your people": your contacts, plus whoever you already share a
/// conversation with. Row-level security computes exactly this set --
/// anyone else is reachable only through ContactsRepository.findByTag.
final yourPeopleProvider = FutureProvider<List<Member>>((ref) async {
  // Depends on who "you" are.
  ref.watch(currentUserIdProvider);
  return switch (await ref.read(chatRepositoryProvider).members()) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: _never);

final contactsRepositoryProvider = Provider<ContactsRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// The caller's own contacts (add/remove) and the exact-tag lookup, as one
/// state machine: `state` is always the current set of contact user ids,
/// kept in sync with every add/remove so a screen watching it updates at
/// once, without waiting for a re-fetch.
final contactsControllerProvider =
    AsyncNotifierProvider.autoDispose<ContactsController, Set<String>>(
      ContactsController.new,
      retry: _never,
    );

class ContactsController extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    ref.watch(currentUserIdProvider);
    return switch (await ref.read(contactsRepositoryProvider).ids()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
  }

  /// The one allowlisted member with this exact tag, or null. See
  /// [ContactsRepository.findByTag] for the rate-limit error shape.
  Future<Result<Member?>> findByTag(String tag) =>
      ref.read(contactsRepositoryProvider).findByTag(tag);

  Future<Result<void>> add(String userId) async {
    final result = await ref.read(contactsRepositoryProvider).add(userId);
    if (result is Ok && ref.mounted) {
      state = AsyncData({...(state.value ?? const <String>{}), userId});
      // A newly added contact belongs in "your people" too.
      ref.invalidate(yourPeopleProvider);
    }
    return result;
  }

  Future<Result<void>> remove(String userId) async {
    final result = await ref.read(contactsRepositoryProvider).remove(userId);
    if (result is Ok && ref.mounted) {
      state = AsyncData({...(state.value ?? const <String>{})}..remove(userId));
      ref.invalidate(yourPeopleProvider);
    }
    return result;
  }
}
