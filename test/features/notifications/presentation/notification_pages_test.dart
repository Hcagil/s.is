// NotificationsScreen and MuteTile, written from the contract: the switch
// and radios save at once and revert on a refused save, the load failure
// shows its reason with a retry, the Muted section lists active mutes only,
// and MuteTile's sheet mutes or unmutes the exact kind and target it was
// given.
//
// NotificationsScreen is reached the way a member reaches it — the whole app
// behind the session gate, fakes only at the repository boundary — except
// its own loading and failure states, which are reached by mounting the
// screen alone the way settings_pages_test.dart does for SettingsScreen.
// MuteTile is mounted alone: it needs nothing from chat, only the mutes
// repository.
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
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/notifications/presentation/notification_pages.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../../support/fakes.dart';
import '../../../support/sis_ui.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<void> pumpApp(
  WidgetTester t, {
  NotificationSettingsFake? notif,
  ChatFake? chat,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(
          FakeAuth(session: true, member: me),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(chat ?? ChatFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(
          ProfileFake(
            profile: const OwnProfile(
              userId: 'u1',
              displayName: 'Maya',
              tag: 'maya',
              onboardingDone: true,
            ),
          ),
        ),
        notificationSettingsRepositoryProvider.overrideWithValue(
          notif ?? NotificationSettingsFake(),
        ),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Future<void> openNotifications(WidgetTester t) async {
  await t.tap(byKey('home-settings'));
  await t.pumpAndSettle();
  expect(byKey('settings-notifications'), findsOneWidget);
  await t.tap(byKey('settings-notifications'));
  await t.pumpAndSettle();
  expect(
    find.descendant(
      of: find.byType(AppBar),
      matching: find.text('Notifications'),
    ),
    findsOneWidget,
  );
}

bool switchOn(WidgetTester t) => switchedOn(t, byKey('notif-enabled'));

bool radioSelected(WidgetTester t, String key) => choiceSelected(t, byKey(key));

/// A minimal host for [MuteTile]: it reads only the mutes repository and
/// `currentUserIdProvider`, so nothing else needs a fake.
Widget aloneMuteTile(
  NotificationSettingsFake fake, {
  required MuteKind kind,
  required String target,
}) => ProviderScope(
  overrides: [notificationSettingsRepositoryProvider.overrideWithValue(fake)],
  child: MaterialApp(
    home: Scaffold(
      body: MuteTile(kind: kind, target: target),
    ),
  ),
);

void main() {
  group('the settings hub', () {
    testWidgets('settings-notifications opens "Notifications"', (t) async {
      await pumpApp(t);
      await openNotifications(t);
      expect(find.byType(NotificationsScreen), findsOneWidget);
    });
  });

  group('NotificationsScreen: enabled switch', () {
    testWidgets('shows the saved value and saves a change at once', (t) async {
      final fake = NotificationSettingsFake(
        settings: const NotificationSettings(enabled: false),
      );
      await pumpApp(t, notif: fake);
      await openNotifications(t);

      expect(switchOn(t), isFalse);
      await t.tap(byKey('notif-enabled'));
      await t.pumpAndSettle();

      expect(switchOn(t), isTrue);
      expect(fake.saves.single.enabled, isTrue);
      expect(
        fake.saves.single.preview,
        NotificationPreview.full,
        reason: 'only the changed field should differ from what was saved',
      );
    });

    testWidgets('a refused save keeps the switch as it was and shows why', (
      t,
    ) async {
      final fake = NotificationSettingsFake()
        ..saveResult = const Err(NetworkFailure('no route to host'));
      await pumpApp(t, notif: fake);
      await openNotifications(t);
      expect(switchOn(t), isTrue, reason: 'setup');

      await t.tap(byKey('notif-enabled'));
      await t.pumpAndSettle();

      expect(switchOn(t), isTrue, reason: 'a refused save must not change it');
      expect(find.textContaining('no route to host'), findsOneWidget);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });
  });

  group('NotificationsScreen: preview radios', () {
    testWidgets('are titled and shown with an example, and the saved one is '
        'selected', (t) async {
      final fake = NotificationSettingsFake(
        settings: const NotificationSettings(
          preview: NotificationPreview.sender,
        ),
      );
      await pumpApp(t, notif: fake);
      await openNotifications(t);

      for (final (key, title, example) in [
        ('notif-preview-full', 'Name and message', 'Ayşe: See you at 8'),
        ('notif-preview-sender', 'Only who it is from', 'Ayşe: New message'),
        ('notif-preview-none', 'No details', 'SIS: New message'),
      ]) {
        await t.ensureVisible(byKey(key));
        expect(
          find.descendant(of: byKey(key), matching: find.text(title)),
          findsOneWidget,
          reason: '$key title',
        );
        expect(
          find.descendant(of: byKey(key), matching: find.text(example)),
          findsOneWidget,
          reason: '$key example',
        );
      }
      expect(radioSelected(t, 'notif-preview-sender'), isTrue);
      expect(radioSelected(t, 'notif-preview-full'), isFalse);
      expect(radioSelected(t, 'notif-preview-none'), isFalse);
    });

    testWidgets('picking one saves it and selects it at once', (t) async {
      final fake = NotificationSettingsFake();
      await pumpApp(t, notif: fake);
      await openNotifications(t);
      expect(radioSelected(t, 'notif-preview-full'), isTrue, reason: 'setup');

      await t.ensureVisible(byKey('notif-preview-none'));
      await t.tap(byKey('notif-preview-none'));
      await t.pumpAndSettle();

      expect(radioSelected(t, 'notif-preview-none'), isTrue);
      expect(radioSelected(t, 'notif-preview-full'), isFalse);
      expect(fake.saves.single.preview, NotificationPreview.none);
      expect(
        fake.saves.single.enabled,
        isTrue,
        reason: 'only preview was asked to change',
      );
    });

    testWidgets('a refused save keeps the old one selected and shows why', (
      t,
    ) async {
      final fake = NotificationSettingsFake()
        ..saveResult = const Err(NetworkFailure('the server refused'));
      await pumpApp(t, notif: fake);
      await openNotifications(t);

      await t.ensureVisible(byKey('notif-preview-none'));
      await t.tap(byKey('notif-preview-none'));
      await t.pumpAndSettle();

      expect(radioSelected(t, 'notif-preview-full'), isTrue);
      expect(radioSelected(t, 'notif-preview-none'), isFalse);
      expect(find.textContaining('the server refused'), findsOneWidget);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });
  });

  group('NotificationsScreen: load failure', () {
    Widget alone(NotificationSettingsFake fake) => ProviderScope(
      overrides: [
        notificationSettingsRepositoryProvider.overrideWithValue(fake),
        chatRepositoryProvider.overrideWithValue(ChatFake()),
      ],
      child: const MaterialApp(home: NotificationsScreen()),
    );

    testWidgets('shows a spinner, then the reason and Try again', (t) async {
      final fake = NotificationSettingsFake()..holdLoad();
      await t.pumpWidget(alone(fake));
      await t.pump();
      expect(sisWait, findsOneWidget);

      fake.loadResult = const Err(NetworkFailure('no route to host'));
      fake.releaseLoad();
      await t.pumpAndSettle();

      expect(find.textContaining('no route to host'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      fake.loadResult = null;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();

      expect(find.textContaining('no route to host'), findsNothing);
      expect(byKey('notif-enabled'), findsOneWidget);
    });
  });

  group('NotificationsScreen: Muted section', () {
    testWidgets('lists only active mutes, by name or chat label, with their '
        'label and an Unmute button; expired ones are not shown', (t) async {
      final now = DateTime.now();
      final fake = NotificationSettingsFake(
        mutes: [
          Mute(
            kind: MuteKind.person,
            target: bob.userId,
            until: now.add(const Duration(hours: 1)),
          ),
          const Mute(kind: MuteKind.conversation, target: 'g1'), // always
          Mute(
            kind: MuteKind.person,
            target: 'expired-person',
            until: now.subtract(const Duration(minutes: 1)),
          ),
        ],
      );
      final chat = ChatFake()
        ..membersResult = const Ok([bob])
        ..conversationsResult = const Ok([
          Conversation(id: 'g1', title: 'Club'),
        ]);
      await pumpApp(t, notif: fake, chat: chat);
      await openNotifications(t);

      expect(find.text('Nothing is muted'), findsNothing);
      expect(find.text(bob.displayName), findsOneWidget);
      expect(find.text('Club'), findsOneWidget);
      expect(find.textContaining('expired-person'), findsNothing);
      expect(byKey('unmute-person-${bob.userId}'), findsOneWidget);
      expect(byKey('unmute-conversation-g1'), findsOneWidget);
      expect(byKey('unmute-person-expired-person'), findsNothing);
      expect(find.text('Always'), findsOneWidget, reason: "g1's label");
    });

    testWidgets('unmuting removes the row', (t) async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'ub')],
      );
      final chat = ChatFake()..membersResult = const Ok([bob]);
      await pumpApp(t, notif: fake, chat: chat);
      await openNotifications(t);
      expect(find.text(bob.displayName), findsOneWidget);

      await t.tap(byKey('unmute-person-ub'));
      await t.pumpAndSettle();

      expect(fake.unmuteCalls.single, (MuteKind.person, 'ub'));
      expect(find.text(bob.displayName), findsNothing);
      expect(find.text('Nothing is muted'), findsOneWidget);
    });

    testWidgets('nothing muted reads "Nothing is muted"', (t) async {
      await pumpApp(t, notif: NotificationSettingsFake());
      await openNotifications(t);
      expect(find.text('Nothing is muted'), findsOneWidget);
    });

    testWidgets('a refused unmute keeps the row and shows why', (t) async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'ub')],
      )..unmuteResult = const Err(NetworkFailure('offline'));
      final chat = ChatFake()..membersResult = const Ok([bob]);
      await pumpApp(t, notif: fake, chat: chat);
      await openNotifications(t);

      await t.tap(byKey('unmute-person-ub'));
      await t.pumpAndSettle();

      expect(find.text(bob.displayName), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });
  });

  group('MuteTile', () {
    testWidgets('unmuted: "Mute notifications", no unmute option', (t) async {
      final fake = NotificationSettingsFake();
      await t.pumpWidget(
        aloneMuteTile(fake, kind: MuteKind.person, target: 'ub'),
      );
      await t.pumpAndSettle();

      expect(find.text('Mute notifications'), findsOneWidget);
      expect(find.text('Muted'), findsNothing);

      await t.tap(byKey('mute-tile'));
      await t.pumpAndSettle();

      expect(byKey('mute-eightHours'), findsOneWidget);
      expect(byKey('mute-oneWeek'), findsOneWidget);
      expect(byKey('mute-always'), findsOneWidget);
      expect(byKey('mute-off'), findsNothing);
    });

    testWidgets('picking a length mutes exactly that kind and target, and '
        'the tile shows Muted', (t) async {
      final fake = NotificationSettingsFake();
      await t.pumpWidget(
        aloneMuteTile(fake, kind: MuteKind.conversation, target: 'g1'),
      );
      await t.pumpAndSettle();

      await t.tap(byKey('mute-tile'));
      await t.pumpAndSettle();
      await t.tap(byKey('mute-eightHours'));
      await t.pumpAndSettle();

      final (kind, target, until) = fake.muteCalls.single;
      expect((kind, target), (MuteKind.conversation, 'g1'));
      expect(until, isNotNull);
      expect(find.text('Muted'), findsOneWidget);
      expect(find.text('Mute notifications'), findsNothing);
      expect(find.textContaining('Until'), findsOneWidget);
    });

    testWidgets('a muted tile\'s sheet offers Unmute, which clears it', (
      t,
    ) async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'ub')],
      );
      await t.pumpWidget(
        aloneMuteTile(fake, kind: MuteKind.person, target: 'ub'),
      );
      await t.pumpAndSettle();
      expect(find.text('Muted'), findsOneWidget);

      await t.tap(byKey('mute-tile'));
      await t.pumpAndSettle();
      expect(byKey('mute-off'), findsOneWidget);
      await t.tap(byKey('mute-off'));
      await t.pumpAndSettle();

      expect(fake.unmuteCalls.single, (MuteKind.person, 'ub'));
      expect(find.text('Mute notifications'), findsOneWidget);
      expect(find.text('Muted'), findsNothing);
    });

    testWidgets('a refused mute shows why and the tile stays unmuted', (
      t,
    ) async {
      final fake = NotificationSettingsFake()
        ..muteResult = const Err(NetworkFailure('the server refused'));
      await t.pumpWidget(
        aloneMuteTile(fake, kind: MuteKind.person, target: 'ub'),
      );
      await t.pumpAndSettle();

      await t.tap(byKey('mute-tile'));
      await t.pumpAndSettle();
      await t.tap(byKey('mute-oneWeek'));
      await t.pumpAndSettle();

      expect(find.text('Mute notifications'), findsOneWidget);
      expect(find.textContaining('the server refused'), findsOneWidget);
      await drainNotice(t);
    });
  });
}
