// Find people from your contacts (step 16), reached the way a member reaches
// it: the whole app as main.dart mounts it, New chat, then the "Find people
// from contacts" row. Fakes stand only at the boundaries (phone book,
// disclosure flag, repositories); every provider, controller and widget in
// between is the production one. Written from the contract, by its keys.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/shared_prefs_contacts_disclosure_store.dart';
import 'package:sis/features/chat/domain/phone_book.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/contact_fakes.dart';
import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(
  userId: 'u2',
  displayName: 'Bob Stone',
  tag: 'bobby',
  email: 'bob@mail.test',
);

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const discBody =
    'SIS sends the email addresses in your contacts, in coded (hashed) form, '
    'to the SIS server to show which of your contacts use SIS. This happens '
    'each time you open Find people. The codes are not stored; SIS only keeps '
    'a note of which members you found. Names and phone numbers stay on your '
    'phone.';

class World {
  World({
    bool accepted = false,
    int budget = 3,
    this.user = me,
    this.disclosure,
  }) : store = FakeDisclosureStore(isAccepted: accepted) {
    contacts.contactsBudget = budget;
    chat.conversationsResult = const Ok([]);
    chat.membersResult = const Ok([]);
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2));
  final contacts = ContactsFake(directory: [me, bob]);
  final FakeDisclosureStore store;

  /// Who is signed in on this run of the app.
  final Member user;

  /// The real store, when a test needs it instead of [store].
  final ContactsDisclosureStore? disclosure;
  final book = FakePhoneBook(
    persons: const [
      PhoneBookPerson(id: '1', name: 'Bobby', emails: ['bob@mail.test']),
      PhoneBookPerson(id: '2', name: 'Dan', emails: ['dan@mail.test']),
    ],
  );
  late final profile = ProfileFake(
    profile: OwnProfile(
      userId: user.userId,
      displayName: user.displayName,
      tag: user.tag!,
      onboardingDone: true,
    ),
  );

  Widget app() => ProviderScope(
    overrides: [
      ...videoOverrides(),
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: user),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      contactsRepositoryProvider.overrideWithValue(contacts),
      contactsDisclosureStoreProvider.overrideWithValue(disclosure ?? store),
      phoneBookProvider.overrideWithValue(book),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      profileRepositoryProvider.overrideWithValue(profile),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key));

Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text), matchRoot: true);

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await steps(t, 30);
}

Future<void> openFind(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await steps(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
  await tapKey(t, 'new-chat');
  await tapKey(t, 'find-from-contacts');
  expect(byKey('find-from-contacts-page'), findsOneWidget);
}

Future<void> back(WidgetTester t) async {
  Navigator.of(t.element(byKey('find-from-contacts-page'))).pop();
  await steps(t, 40);
  expect(byKey('find-from-contacts-page'), findsNothing);
}

void main() {
  group('disclosure', () {
    testWidgets('shows the disclosure first; nothing is read or sent', (
      t,
    ) async {
      final w = World();
      await openFind(t, w);
      expect(find.text('Find people from your contacts'), findsWidgets);
      expect(find.text(discBody), findsOneWidget);
      expect(byKey('find-primary'), findsOneWidget);
      expect(byKey('find-not-now'), findsOneWidget);
      expect(w.book.accessCalls, 0);
      expect(w.book.peopleCalls, 0);
      expect(w.contacts.contactCalls, isEmpty);
    });

    testWidgets('Not now closes the page and uploads nothing', (t) async {
      final w = World();
      await openFind(t, w);
      await tapKey(t, 'find-not-now');
      expect(byKey('find-from-contacts-page'), findsNothing);
      expect(
        byKey('find-from-contacts'),
        findsOneWidget,
        reason: 'back on New chat',
      );
      await steps(t, 20);
      expect(w.store.isAccepted, isFalse);
      expect(w.book.accessCalls, 0);
      expect(w.book.peopleCalls, 0);
      expect(w.contacts.contactCalls, isEmpty);
      // It asks again next time.
      await tapKey(t, 'find-from-contacts');
      expect(byKey('find-not-now'), findsOneWidget);
    });

    testWidgets('Continue remembers it, then shows who is on SIS', (t) async {
      final w = World();
      await openFind(t, w);
      await tapKey(t, 'find-primary');
      expect(w.store.isAccepted, isTrue);
      expect(w.contacts.contactCalls, hasLength(1));
      expect(byKey('find-on-u2'), findsOneWidget);
      expect(byKey('find-message-u2'), findsOneWidget);
      expect(byKey('find-off-0'), findsOneWidget);
      expect(under('find-off-0', 'Dan'), findsOneWidget);
      expect(byKey('find-on-u1'), findsNothing);
    });
  });

  group('results', () {
    testWidgets('Invite stays grey and there is no Select all', (t) async {
      final w = World(accepted: true);
      await openFind(t, w);
      expect(byKey('grey-f_inv'), findsWidgets);
      expect(
        find.descendant(of: byKey('find-off-0'), matching: byKey('grey-f_inv')),
        findsOneWidget,
      );
      expect(find.textContaining('Select all'), findsNothing);
      expect(find.textContaining('select all'), findsNothing);
    });

    testWidgets('Message returns the member through New chat and opens the '
        'chat', (t) async {
      final w = World(accepted: true)..chat.startResult = const Ok('c-bob');
      await openFind(t, w);
      await tapKey(t, 'find-message-u2');
      await steps(t, 30);
      expect(byKey('find-from-contacts-page'), findsNothing);
      expect(w.chat.started, ['u2']);
      expect(find.byType(MessageScreen), findsOneWidget);
    });

    testWidgets('each opening re-runs the lookup (the disclosure says '
        'so); at the limit the last result stays with Try again later', (
      t,
    ) async {
      final w = World(accepted: true, budget: 1);
      await openFind(t, w);
      expect(byKey('find-on-u2'), findsOneWidget);
      expect(byKey('find-limited'), findsNothing);
      await back(t);
      await tapKey(t, 'find-from-contacts');
      expect(
        w.contacts.contactCalls,
        hasLength(2),
        reason: 'reopening re-runs',
      );
      expect(under('find-limited', 'Try again later.'), findsOneWidget);
      expect(byKey('find-on-u2'), findsOneWidget);
    });

    testWidgets('a limit hit on the first opening shows Try again later', (
      t,
    ) async {
      final w = World(accepted: true, budget: 0);
      await openFind(t, w);
      expect(w.contacts.contactCalls, hasLength(1));
      expect(under('find-limited', 'Try again later.'), findsOneWidget);
      expect(byKey('find-on-u2'), findsNothing);
    });

    testWidgets('a refused permission asks again from the page', (t) async {
      final w = World(accepted: true);
      w.book.access = PhoneBookAccess.denied;
      await openFind(t, w);
      expect(byKey('find-on-u2'), findsNothing);
      expect(w.contacts.contactCalls, isEmpty);
      final asked = w.book.accessCalls;
      w.book.access = PhoneBookAccess.granted;
      await tapKey(t, 'find-primary');
      expect(w.book.accessCalls, greaterThan(asked));
      expect(byKey('find-on-u2'), findsOneWidget);
    });
  });

  group('two accounts on one phone', () {
    const nora = Member(userId: 'u7', displayName: 'Nora Lake', tag: 'nora');

    // One phone: shared_preferences persists between runs of the app; the
    // real store reads the signed-in user id the way main.dart wires it.
    Future<void> run(WidgetTester t, Member user) async {
      await t.pumpWidget(const SizedBox()); // the previous run ends
      final w = World(
        user: user,
        disclosure: SharedPrefsContactsDisclosureStore(() => user.userId),
      );
      await openFind(t, w);
    }

    testWidgets('a second account sees the disclosure again; the first '
        'keeps its acceptance', (t) async {
      SharedPreferences.setMockInitialValues({});
      await run(t, me);
      expect(byKey('find-not-now'), findsOneWidget);
      await tapKey(t, 'find-primary');
      expect(byKey('find-on-u2'), findsOneWidget);

      await run(t, nora);
      expect(
        byKey('find-not-now'),
        findsOneWidget,
        reason: "Maya's acceptance must not count for Nora",
      );
      expect(byKey('find-on-u2'), findsNothing);

      await run(t, me);
      expect(byKey('find-not-now'), findsNothing, reason: 'Maya accepted');
      expect(byKey('find-on-u2'), findsOneWidget);
    });
  });
}
