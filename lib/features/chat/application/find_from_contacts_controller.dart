part of 'chat_controllers.dart';

/// What Find people from contacts shows.
sealed class FindContactsState {
  const FindContactsState();
}

/// The first-use disclosure was not accepted yet; nothing is read or sent.
final class FindNeedsConsent extends FindContactsState {
  const FindNeedsConsent();
}

/// Contacts access refused; [permanent]: only the app's settings help.
final class FindDenied extends FindContactsState {
  const FindDenied({required this.permanent});
  final bool permanent;
}

/// A phone contact that is a SIS member.
final class FoundContact {
  const FoundContact({required this.name, required this.member});
  final String name;
  final Member member;
}

/// The lookup result. [limited]: the server limit was hit, so this is the
/// last result of this session (or empty).
final class FindResult extends FindContactsState {
  const FindResult({
    required this.onSis,
    required this.notOnSis,
    this.limited = false,
  });
  final List<FoundContact> onSis;
  final List<String> notOnSis;
  final bool limited;
}

final contactsDisclosureStoreProvider = Provider<ContactsDisclosureStore>(
  (_) => throw UnimplementedError('override in main'),
);

final findFromContactsControllerProvider =
    AsyncNotifierProvider.autoDispose<
      FindFromContactsController,
      FindContactsState
    >(FindFromContactsController.new, retry: _never);

/// The last result of this session; outlives the page so a reopening that hits
/// the limit can still show it.
final _lastFindProvider = Provider<_LastFind>((_) => _LastFind());

class _LastFind {
  FindResult? result;
  String? user;
}

class FindFromContactsController extends AsyncNotifier<FindContactsState> {
  @override
  Future<FindContactsState> build() async {
    final uid = ref.watch(currentUserIdProvider);
    final mem = ref.read(_lastFindProvider);
    if (uid != mem.user) {
      mem.result = null; // never carry one member's result to the next
      mem.user = uid;
    }
    if (!await ref.read(contactsDisclosureStoreProvider).accepted()) {
      return const FindNeedsConsent();
    }
    return _load();
  }

  /// [Continue] on the disclosure: remember it, then read and look up.
  Future<void> accept() async {
    await ref.read(contactsDisclosureStoreProvider).accept();
    await _run();
  }

  /// [Allow contacts]: asks again, or opens settings after a permanent refusal.
  Future<void> allow() async {
    final cur = state.value;
    if (cur is FindDenied && cur.permanent) {
      await ref.read(phoneBookProvider).openSettings();
      return;
    }
    await _run();
  }

  Future<void> _run() async {
    state = const AsyncLoading();
    final next = await AsyncValue.guard(_load);
    if (ref.mounted) state = next;
  }

  Future<FindContactsState> _load() async {
    final book = ref.read(phoneBookProvider);
    switch (await book.requestAccess()) {
      case PhoneBookAccess.denied:
        return const FindDenied(permanent: false);
      case PhoneBookAccess.permanentlyDenied:
        return const FindDenied(permanent: true);
      case PhoneBookAccess.granted:
        break;
    }
    final people = await book.people();
    final hashes = {
      for (final p in people)
        for (final e in p.emails) hashContactEmail(e),
    }.toList()..sort(); // stable order: the same 2000 go every time
    final send = hashes.take(2000).toList();
    final hit = <String, Member>{};
    if (send.isNotEmpty) {
      switch (await ref.read(contactsRepositoryProvider).findByContacts(send)) {
        case Ok(:final value):
          for (final m in value) {
            hit[m.hash] = m.member;
          }
        case Err(failure: SearchLimitFailure()):
          return FindResult(
            onSis: ref.read(_lastFindProvider).result?.onSis ?? const [],
            notOnSis: ref.read(_lastFindProvider).result?.notOnSis ?? const [],
            limited: true,
          );
        case Err(:final failure):
          throw failure;
      }
    }
    final onSis = <FoundContact>[];
    final notOnSis = <String>[];
    final seen = <String>{};
    for (final p in people) {
      Member? member;
      for (final e in p.emails) {
        member ??= hit[hashContactEmail(e)];
      }
      if (member == null) {
        notOnSis.add(p.name);
      } else if (seen.add(member.userId)) {
        onSis.add(FoundContact(name: p.name, member: member));
      }
    }
    return ref.read(_lastFindProvider).result = FindResult(
      onSis: onSis,
      notOnSis: notOnSis,
    );
  }
}
