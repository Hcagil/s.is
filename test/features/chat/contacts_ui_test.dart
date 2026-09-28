// Contacts, exact-tag search and picture privacy (v0.22.0), written from the
// contract in docs/DECISIONS.md ("Contacts, exact-tag search, and who sees
// your picture") and reached the way a member reaches them: the whole app as
// main.dart mounts it, New chat tapped, a person's page opened from a chat,
// Settings > Privacy. Fakes stand only at the repository boundaries; every
// provider, controller and widget between them is the production one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const dee = Member(userId: 'ud', displayName: 'Dee Kurt', tag: 'dee');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

/// Bob shares a chat with Maya, Dee is a contact she saved, Cem is a
/// stranger only an exact tag can find. The chat fake's member list is what
/// `profiles_public()` would return: re-derived whenever contacts change.
class World {
  World({OwnProfile? own}) {
    contacts.onChanged = _people;
    _people();
    chat
      ..conversationsResult = const Ok([withBob])
      ..roster['c1'] = [me, bob];
    if (own != null) profile.profile = own;
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2));
  final contacts = ContactsFake(
    directory: [me, bob, dee, cem],
    reachable: ['ub'],
    saved: ['ud'],
  );
  final profile = ProfileFake(
    profile: const OwnProfile(
      userId: 'u1',
      displayName: 'Maya Kaya',
      tag: 'maya',
      onboardingDone: true,
    ),
  );

  void _people() => chat.membersResult = Ok([
    for (final m in contacts.directory.values)
      if (contacts.reachable.contains(m.userId) ||
          contacts.saved.contains(m.userId))
        m,
  ]);

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: me),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      contactsRepositoryProvider.overrideWithValue(contacts),
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

/// What the found row's add/remove button says (its tooltip and label).
String? toggleSays(WidgetTester t, String id) =>
    t.widget<IconButton>(byKey('find-by-tag-toggle-$id')).tooltip;

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> pumpApp(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await steps(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await steps(t);
}

Future<void> openNewChat(WidgetTester t) => tapKey(t, 'new-chat');

/// Closes the New chat picker the way a back gesture does, and opens it again.
Future<void> reopenNewChat(WidgetTester t) async {
  Navigator.of(t.element(byKey('find-by-tag-field'))).pop();
  await steps(t);
  expect(byKey('find-by-tag-field'), findsNothing);
  await openNewChat(t);
}

Future<void> search(WidgetTester t, String tag) async {
  await t.enterText(byKey('find-by-tag-field'), tag);
  await t.pump();
  await tapKey(t, 'find-by-tag-submit');
}

Future<void> openPersonPage(WidgetTester t) async {
  await tapKey(t, 'conversation-c1');
  expect(find.byType(MessageScreen), findsOneWidget);
  await tapKey(t, 'conversation-title');
  expect(byKey('person-contact-toggle'), findsOneWidget);
}

void main() {
  group('New chat', () {
    testWidgets('lists your people, and nobody else', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openNewChat(t);

      expect(byKey('member-ub'), findsOneWidget, reason: 'chat partner');
      expect(byKey('member-ud'), findsOneWidget, reason: 'saved contact');
      expect(byKey('member-u3'), findsNothing, reason: 'a stranger');
      expect(find.text('Cem Ay'), findsNothing);
      expect(byKey('find-by-tag-field'), findsOneWidget);
      expect(find.text('Find by exact tag'), findsOneWidget);
    });

    testWidgets('an exact tag finds the one person who has it', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openNewChat(t);
      await search(t, '@CEM');

      expect(byKey('find-by-tag-result-u3'), findsOneWidget);
      expect(under('find-by-tag-result-u3', 'Cem Ay'), findsOneWidget);
      expect(under('find-by-tag-result-u3', '@cem'), findsOneWidget);
      expect(w.contacts.finds, 1);
      expect(byKey('find-by-tag-empty'), findsNothing);
    });

    testWidgets('a tag nobody has says so, and suggests nobody', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openNewChat(t);
      await search(t, 'ce');

      expect(under('find-by-tag-empty', 'Nobody has that tag'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (x) =>
              x.key is ValueKey<String> &&
              (x.key! as ValueKey<String>).value.startsWith(
                'find-by-tag-result-',
              ),
        ),
        findsNothing,
      );
    });

    testWidgets('a rate-limited search shows the server message and does '
        'not retry by itself', (t) async {
      final w = World()
        ..contacts.findResult = const Err(ContactsFake.rateLimited);
      await pumpApp(t, w);
      await openNewChat(t);
      await search(t, 'cem');

      expect(
        under('find-by-tag-error', 'Too many searches, try again later.'),
        findsOneWidget,
      );
      expect(byKey('find-by-tag-result-u3'), findsNothing);
      await t.pump(const Duration(seconds: 5));
      await steps(t);
      expect(w.contacts.finds, 1, reason: 'retried without being asked');
    });

    testWidgets('the 21st search in a row is refused like the server does', (
      t,
    ) async {
      final w = World();
      await pumpApp(t, w);
      await openNewChat(t);
      for (var i = 0; i < 20; i++) {
        await search(t, 'nobody$i');
      }
      expect(byKey('find-by-tag-error'), findsNothing);
      await search(t, 'cem');
      expect(
        under('find-by-tag-error', 'Too many searches, try again later.'),
        findsOneWidget,
      );
      expect(byKey('find-by-tag-result-u3'), findsNothing);
    });

    testWidgets('the found person can be added, then removed', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openNewChat(t);
      await search(t, 'cem');

      expect(toggleSays(t, 'u3'), 'Add to contacts');
      await tapKey(t, 'find-by-tag-toggle-u3');
      expect(w.contacts.saved, contains('u3'));
      expect(toggleSays(t, 'u3'), 'Remove from contacts');
      await drainNotice(t);
      await reopenNewChat(t);
      expect(
        byKey('member-u3'),
        findsOneWidget,
        reason: 'your people were not re-read after the add',
      );

      await search(t, 'cem');
      expect(toggleSays(t, 'u3'), 'Remove from contacts');
      await tapKey(t, 'find-by-tag-toggle-u3');
      expect(w.contacts.saved, isNot(contains('u3')));
      expect(toggleSays(t, 'u3'), 'Add to contacts');
      await drainNotice(t);
      await reopenNewChat(t);
      expect(
        byKey('member-u3'),
        findsNothing,
        reason: 'your people were not re-read after the removal',
      );
    });

    testWidgets('a refused add leaves the person unsaved', (t) async {
      final w = World()
        ..contacts.addResult = const Err(NetworkFailure('offline'));
      await pumpApp(t, w);
      await openNewChat(t);
      await search(t, 'cem');
      await tapKey(t, 'find-by-tag-toggle-u3');

      expect(w.contacts.saved, isNot(contains('u3')));
      expect(toggleSays(t, 'u3'), 'Add to contacts');
      expect(byKey('member-u3'), findsNothing);
      await drainNotice(t);
    });

    testWidgets('Chat on the found person starts the chat and opens it', (
      t,
    ) async {
      final w = World()..chat.startResult = const Ok('c-cem');
      await pumpApp(t, w);
      await openNewChat(t);
      await search(t, 'cem');
      await tapKey(t, 'find-by-tag-chat-u3');

      expect(w.chat.started, ['u3']);
      expect(find.byType(MessageScreen), findsOneWidget);
    });

    testWidgets('a person whose picture is hidden from you shows initials', (
      t,
    ) async {
      final w = World();
      await pumpApp(t, w);
      await openNewChat(t);

      // Dee's avatarPath came back null: the server masked it.
      expect(under('member-ud', 'DK'), findsOneWidget);
    });
  });

  group('person page', () {
    testWidgets('adds to and removes from contacts', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openPersonPage(t);

      expect(under('person-contact-toggle', 'Add to contacts'), findsOneWidget);
      await tapKey(t, 'person-contact-toggle');
      expect(w.contacts.saved, contains('ub'));
      expect(
        under('person-contact-toggle', 'Remove from contacts'),
        findsOneWidget,
      );

      await tapKey(t, 'person-contact-toggle');
      expect(w.contacts.saved, isNot(contains('ub')));
      expect(under('person-contact-toggle', 'Add to contacts'), findsOneWidget);
      await drainNotice(t);
    });

    testWidgets('shows Remove for someone already saved', (t) async {
      final w = World()..contacts.saved.add('ub');
      await pumpApp(t, w);
      await openPersonPage(t);

      expect(
        under('person-contact-toggle', 'Remove from contacts'),
        findsOneWidget,
      );
    });

    testWidgets('a refused removal keeps the contact', (t) async {
      final w = World()
        ..contacts.saved.add('ub')
        ..contacts.removeResult = const Err(NetworkFailure('offline'));
      await pumpApp(t, w);
      await openPersonPage(t);
      await tapKey(t, 'person-contact-toggle');

      expect(w.contacts.saved, contains('ub'));
      expect(
        under('person-contact-toggle', 'Remove from contacts'),
        findsOneWidget,
      );
      await drainNotice(t);
    });

    testWidgets('an excluded viewer sees the initials', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openPersonPage(t);

      // Bob's avatarPath is null for this viewer: the server masked it.
      expect(under('person-avatar', 'BS'), findsOneWidget);
    });
  });

  group('Settings > Privacy > Profile picture', () {
    Future<void> openPrivacy(WidgetTester t) async {
      await tapKey(t, 'home-settings');
      await tapKey(t, 'settings-privacy');
      await t.ensureVisible(byKey('avatar-visibility-everyone'));
      await t.pump();
    }

    testWidgets('offers Everyone, My contacts and Nobody; Everyone first', (
      t,
    ) async {
      final w = World();
      await pumpApp(t, w);
      await openPrivacy(t);

      for (final (key, label) in [
        ('avatar-visibility-everyone', 'Everyone'),
        ('avatar-visibility-contacts', 'My contacts'),
        ('avatar-visibility-nobody', 'Nobody'),
      ]) {
        expect(under(key, label), findsOneWidget, reason: key);
      }
      expect(choiceSelected(t, byKey('avatar-visibility-everyone')), isTrue);
      expect(choiceSelected(t, byKey('avatar-visibility-contacts')), isFalse);
    });

    testWidgets('a choice is saved and persists', (t) async {
      final w = World();
      await pumpApp(t, w);
      await openPrivacy(t);
      await tapKey(t, 'avatar-visibility-contacts');

      expect(w.profile.saves.last.avatarVisibility, AvatarVisibility.contacts);
      expect(w.profile.profile.avatarVisibility, AvatarVisibility.contacts);
      expect(choiceSelected(t, byKey('avatar-visibility-contacts')), isTrue);
      expect(choiceSelected(t, byKey('avatar-visibility-everyone')), isFalse);

      // A fresh start reads it back from the repository.
      await t.pumpWidget(const SizedBox());
      await steps(t);
      await pumpApp(t, w);
      await openPrivacy(t);
      expect(choiceSelected(t, byKey('avatar-visibility-contacts')), isTrue);
    });

    testWidgets('a refused save does not show the new choice', (t) async {
      final w = World()
        ..profile.saveResult = const Err(NetworkFailure('offline'));
      await pumpApp(t, w);
      await openPrivacy(t);
      await tapKey(t, 'avatar-visibility-nobody');

      expect(w.profile.profile.avatarVisibility, AvatarVisibility.everyone);
      expect(choiceSelected(t, byKey('avatar-visibility-everyone')), isTrue);
      expect(choiceSelected(t, byKey('avatar-visibility-nobody')), isFalse);
      await drainNotice(t);
    });
  });
}
