// FindFromContactsController against FakePhoneBook, FakeDisclosureStore and
// ContactsFake (test/support), written from the step-16 contract, not the
// code: nothing is read or sent before the disclosure is accepted; hashes are
// deduped, sorted and capped at 2000; no hashes means no server call; a limit
// hit shows the last result of this session (or empty) as limited; a user
// change clears it; other errors are AsyncError; no email or hash is logged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/phone_book.dart';

import '../../support/contact_fakes.dart';
import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const other = Member(userId: 'u9', displayName: 'Nora');

/// A session that can switch account, like signing in as someone else.
class _Session extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);

  void become(Member m) => state = AsyncData(Allowed(m));
}

/// The contract's hash, computed here rather than by the code under test.
String hashOf(String email) =>
    sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

const bob = Member(
  userId: 'u2',
  displayName: 'Bob',
  tag: 'bob',
  email: 'bob@mail.test',
);
const cara = Member(
  userId: 'u3',
  displayName: 'Cara',
  tag: 'cara',
  email: 'cara@mail.test',
);

PhoneBookPerson person(
  String id,
  String name, [
  List<String> emails = const [],
]) => PhoneBookPerson(id: id, name: name, emails: emails);

class World {
  World({FakePhoneBook? book, FakeDisclosureStore? store, ContactsFake? repo})
    : book = book ?? FakePhoneBook(),
      store = store ?? FakeDisclosureStore(isAccepted: true),
      repo = repo ?? ContactsFake(directory: [bob, cara]);

  final FakePhoneBook book;
  final FakeDisclosureStore store;
  final ContactsFake repo;
  late final ProviderContainer c;

  Future<World> start() async {
    c = await settled(
      ProviderContainer.test(
        overrides: [
          phoneBookProvider.overrideWithValue(book),
          contactsRepositoryProvider.overrideWithValue(repo),
          contactsDisclosureStoreProvider.overrideWithValue(store),
          sessionControllerProvider.overrideWith(_Session.new),
        ],
      ),
    );
    c.listen(findFromContactsControllerProvider, (_, _) {});
    return this;
  }

  FindFromContactsController get ctrl =>
      c.read(findFromContactsControllerProvider.notifier);

  Future<FindContactsState> settle() async {
    for (var i = 0; i < 400; i++) {
      final v = c.read(findFromContactsControllerProvider);
      if (!v.isLoading) {
        if (v.hasError) return Future.error(v.error!);
        return v.requireValue;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('the controller never settled');
  }

  /// Opening the page again.
  Future<FindContactsState> reopen() {
    c.invalidate(findFromContactsControllerProvider);
    return settle();
  }
}

void main() {
  group('consent', () {
    test('nothing is read, asked or sent before the disclosure', () async {
      final w = await World(
        store: FakeDisclosureStore(),
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      expect(await w.settle(), isA<FindNeedsConsent>());
      // Let any stray background work run.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(w.book.accessCalls, 0, reason: 'no permission prompt');
      expect(w.book.peopleCalls, 0, reason: 'no contacts read');
      expect(w.repo.contactCalls, isEmpty, reason: 'nothing uploaded');
      expect(w.store.acceptCalls, 0);
    });

    test('accept stores the flag, then reads and looks up', () async {
      final w = await World(
        store: FakeDisclosureStore(),
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      await w.settle();
      await w.ctrl.accept();
      final s = await w.settle();
      expect(w.store.isAccepted, isTrue);
      expect(w.book.accessCalls, greaterThan(0));
      expect(w.repo.contactCalls, [
        [hashOf('bob@mail.test')],
      ]);
      expect(s, isA<FindResult>());
      expect((s as FindResult).onSis.map((f) => f.member.userId), ['u2']);
    });

    test('an accepted disclosure goes straight to the lookup', () async {
      final w = await World(
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      final s = await w.settle() as FindResult;
      expect(s.onSis.single.member.userId, 'u2');
      expect(s.onSis.single.name, 'Bobby');
      expect(s.limited, isFalse);
    });
  });

  group('permission', () {
    test('denied: FindDenied(permanent: false), nothing sent', () async {
      final w = await World(
        book: FakePhoneBook(
          access: PhoneBookAccess.denied,
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      final s = await w.settle();
      expect(s, isA<FindDenied>());
      expect((s as FindDenied).permanent, isFalse);
      expect(w.repo.contactCalls, isEmpty);
    });

    test('allow after a refusal asks again and looks up', () async {
      final w = await World(
        book: FakePhoneBook(
          access: PhoneBookAccess.denied,
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      await w.settle();
      final asked = w.book.accessCalls;
      w.book.access = PhoneBookAccess.granted;
      await w.ctrl.allow();
      final s = await w.settle();
      expect(w.book.accessCalls, greaterThan(asked));
      expect(s, isA<FindResult>());
      expect(w.book.settingsCalls, 0);
    });

    test('permanently denied: FindDenied(permanent: true); allow opens '
        'settings', () async {
      final w = await World(
        book: FakePhoneBook(access: PhoneBookAccess.permanentlyDenied),
      ).start();
      final s = await w.settle();
      expect((s as FindDenied).permanent, isTrue);
      await w.ctrl.allow();
      await w.settle();
      expect(w.book.settingsCalls, 1);
      expect(w.repo.contactCalls, isEmpty);
    });
  });

  group('what is sent', () {
    test('hashes of trimmed, lower-cased emails, deduped and sorted', () async {
      final w = await World(
        book: FakePhoneBook(
          persons: [
            person('1', 'Zoe', ['zoe@mail.test', ' Bob@Mail.test ']),
            person('2', 'Bobby', ['bob@mail.test']),
            person('3', 'Al', ['al@mail.test', 'ZOE@mail.test']),
          ],
        ),
      ).start();
      await w.settle();
      final want = {
        hashOf('zoe@mail.test'),
        hashOf('bob@mail.test'),
        hashOf('al@mail.test'),
      }.toList()..sort();
      expect(w.repo.contactCalls, [want]);
    });

    test('at most 2000, the same 2000 on every opening', () async {
      final emails = [for (var i = 0; i < 2500; i++) 'p$i@mail.test'];
      final book = FakePhoneBook(
        persons: [
          for (var i = 0; i < 2500; i++) person('$i', 'P$i', [emails[i]]),
        ],
      );
      final w = await World(
        book: book,
        repo: ContactsFake(directory: [bob])..contactsBudget = 9,
      ).start();
      await w.settle();
      final all = emails.map(hashOf).toList()..sort();
      expect(w.repo.contactCalls.single, all.take(2000).toList());
      // The phone hands contacts back in another order next time.
      book.persons = book.persons.reversed.toList();
      await w.reopen();
      expect(w.repo.contactCalls, hasLength(2));
      expect(w.repo.contactCalls[1], w.repo.contactCalls[0]);
    });

    test('no email anywhere: no server call, everyone is Not on SIS', () async {
      final w = await World(
        book: FakePhoneBook(persons: [person('1', 'Ann'), person('2', 'Ben')]),
      ).start();
      final s = await w.settle() as FindResult;
      expect(w.repo.contactCalls, isEmpty);
      expect(s.onSis, isEmpty);
      expect(s.notOnSis, containsAll(['Ann', 'Ben']));
    });

    test('no contacts at all: no server call', () async {
      final w = await World().start();
      final s = await w.settle() as FindResult;
      expect(w.repo.contactCalls, isEmpty);
      expect(s.onSis, isEmpty);
      expect(s.notOnSis, isEmpty);
    });
  });

  group('result', () {
    test('a member found through two contacts appears once; contacts '
        'without email or a match are Not on SIS', () async {
      final w = await World(
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
            person('2', 'Robert', ['BOB@mail.test']),
            person('3', 'Cara C', ['cara@mail.test']),
            person('4', 'Dan', ['dan@mail.test']),
            person('5', 'Eli'),
          ],
        ),
      ).start();
      final s = await w.settle() as FindResult;
      expect(s.onSis.map((f) => f.member.userId).toList()..sort(), [
        'u2',
        'u3',
      ]);
      expect(s.notOnSis, containsAll(['Dan', 'Eli']));
      expect(s.notOnSis, isNot(contains('Cara C')));
      expect(s.limited, isFalse);
    });

    test('another error is AsyncError', () async {
      final repo = ContactsFake(directory: [bob])
        ..contactsResult = const Err(ProviderFailure('Something went wrong'));
      final w = await World(
        repo: repo,
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      await expectLater(w.settle(), throwsA(anything));
      expect(w.c.read(findFromContactsControllerProvider).hasError, isTrue);
    });
  });

  group('limit', () {
    test(
      'a limit hit shows the last result of this session, limited',
      () async {
        final w = await World(
          repo: ContactsFake(directory: [bob])..contactsBudget = 1,
          book: FakePhoneBook(
            persons: [
              person('1', 'Bobby', ['bob@mail.test']),
            ],
          ),
        ).start();
        final first = await w.settle() as FindResult;
        expect(first.limited, isFalse);
        final again = await w.reopen() as FindResult;
        expect(w.repo.contactCalls, hasLength(2), reason: 'it did ask');
        expect(again.limited, isTrue);
        expect(again.onSis.map((f) => f.member.userId), ['u2']);
      },
    );

    test('a limit hit with no earlier result is empty, limited', () async {
      final w = await World(
        repo: ContactsFake(directory: [bob])..contactsBudget = 0,
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      final s = await w.settle() as FindResult;
      expect(s.limited, isTrue);
      expect(s.onSis, isEmpty);
    });

    test('a user change forgets the last result', () async {
      final w = await World(
        repo: ContactsFake(directory: [bob])..contactsBudget = 1,
        book: FakePhoneBook(
          persons: [
            person('1', 'Bobby', ['bob@mail.test']),
          ],
        ),
      ).start();
      expect((await w.settle() as FindResult).onSis, hasLength(1));
      (w.c.read(sessionControllerProvider.notifier) as _Session).become(other);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // The new account's page runs its own lookup, which hits the limit.
      final s = await w.settle() as FindResult;
      expect(w.repo.contactCalls.length, greaterThanOrEqualTo(2));
      expect(s.limited, isTrue);
      expect(s.onSis, isEmpty, reason: "Maya's result must not reach Nora");
    });
  });

  test('no email or hash is ever logged', () async {
    final lines = <String>[];
    final oldDebugPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    addTearDown(() => debugPrint = oldDebugPrint);
    await runZoned(
      () async {
        final w = await World(
          store: FakeDisclosureStore(),
          repo: ContactsFake(directory: [bob])..contactsBudget = 1,
          book: FakePhoneBook(
            persons: [
              person('1', 'Bobby', ['bob@mail.test']),
              person('2', 'Dan', ['dan@mail.test']),
            ],
          ),
        ).start();
        await w.settle();
        await w.ctrl.accept();
        await w.settle();
        await w.reopen(); // the limit path
        w.repo.contactsResult = const Err(ProviderFailure('boom'));
        w.repo.contactsBudget = 99;
        await w.reopen().catchError((_) => const FindNeedsConsent());
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => lines.add(line),
      ),
    );
    final secrets = [
      'bob@mail.test',
      'dan@mail.test',
      hashOf('bob@mail.test'),
      hashOf('dan@mail.test'),
    ];
    for (final l in lines) {
      for (final s in secrets) {
        expect(l.toLowerCase(), isNot(contains(s)), reason: 'logged: $l');
      }
    }
  });

  // dart:developer log() cannot be captured in a test, so its calls in the
  // files this step added are checked by source: a log line may name an
  // error's type, never interpolate a value (an email, a hash, a list).
  test('log calls in the find path interpolate nothing but a type', () {
    const files = [
      'lib/features/chat/application/find_from_contacts_controller.dart',
      'lib/features/chat/data/supabase_contacts_repository.dart',
      'lib/features/chat/data/shared_prefs_contacts_disclosure_store.dart',
      'lib/features/chat/domain/phone_book.dart',
      'lib/features/chat/presentation/find_from_contacts_page.dart',
      'lib/features/chat/presentation/find_from_contacts_views.dart',
    ];
    final call = RegExp(r'\b(log|print|debugPrint)\(([^;]*);', dotAll: true);
    final interp = RegExp(r'\$\{([^}]*)\}|\$([A-Za-z_]\w*)');
    for (final f in files) {
      for (final m in call.allMatches(File(f).readAsStringSync())) {
        expect(
          m.group(2)!.trimLeft(),
          matches(RegExp('^r?[\'"]')),
          reason: '$f logs a value, not a message: ${m.group(0)}',
        );
        for (final i in interp.allMatches(m.group(2)!)) {
          final expr = i.group(1) ?? i.group(2)!;
          expect(
            expr,
            endsWith('.runtimeType'),
            reason: '$f logs a value: ${m.group(0)}',
          );
        }
      }
    }
  });
}
