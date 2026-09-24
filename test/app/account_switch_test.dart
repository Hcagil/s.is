// The owner's report, replayed through the app as production mounts it.
//
// On one phone heybana signed out and cagilhay signed in. The New chat picker
// then offered cagilhay to herself and did not offer heybana: it was still
// heybana's "everyone else". Only a restart fixed it.
//
// SisApp behind the real session gate, with fakes only at the repositories.
// The fakes share ONE session the way the repositories share one Supabase
// client, so whatever a screen shows after the switch is either re-read as
// cagilhay or left over from heybana — and the two are different.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/account_fakes.dart';
import '../support/fakes.dart'
    show FakeUpdate, PushRegistryFake, PushSourceFake;

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Finder byKey(String k) => find.byKey(ValueKey(k));
Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text));

class Owner {
  Owner(this.t) : backend = onePhoneTwoAccounts() {
    auth = SwitchingAuth(backend);
    chat = SessionChat(backend);
    presence = SessionPresence(backend)..elsewhere = {deniz};
  }

  final WidgetTester t;
  final Backend backend;
  late final SwitchingAuth auth;
  late final SessionChat chat;
  late final SessionPresence presence;
  final pushSource = PushSourceFake();
  final pushRegistry = PushRegistryFake();

  Future<void> start() async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(auth),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(presence),
          profileRepositoryProvider.overrideWithValue(SessionProfile(backend)),
          pushSourceProvider.overrideWithValue(pushSource),
          pushRegistryProvider.overrideWithValue(pushRegistry),
        ],
        child: const SisApp(),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
  }

  ProviderContainer get container =>
      ProviderScope.containerOf(t.element(find.byType(SisApp)));

  Future<void> signInAs(String who) async {
    auth.chosen = who;
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget, reason: 'home not shown');
  }

  Future<void> signOut() async {
    await t.tap(byKey('home-settings'));
    await t.pumpAndSettle();
    await t.tap(byKey('settings-account'));
    await t.pumpAndSettle();
    await t.tap(byKey('account-sign-out'));
    await t.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
  }

  /// Opens the New chat picker, reports whom it offers, and closes it.
  Future<Set<String>> pickerOffers() async {
    await t.tap(byKey('new-chat'));
    await t.pumpAndSettle();
    final offered = {
      for (final id in [heybana, cagilhay, deniz])
        if (byKey('member-$id').evaluate().isNotEmpty) id,
    };
    Navigator.of(t.element(find.byKey(ValueKey('member-$deniz')))).pop();
    await t.pumpAndSettle();
    return offered;
  }

  Set<String> listed() => {
    for (final id in ['c-ab', 'c-ac', 'c-bc'])
      if (byKey('conversation-$id').evaluate().isNotEmpty) id,
  };

  Future<void> openAndLeave(String conversation, String expectBody) async {
    await t.tap(byKey('conversation-$conversation'));
    await t.pumpAndSettle();
    expect(find.text(expectBody), findsOneWidget, reason: 'did not open');
    await t.pageBack();
    await t.pumpAndSettle();
  }

  /// Settings as the member sees them: the profile card, then Account.
  Future<void> expectSettings({
    required String name,
    required String tag,
    required String email,
    required String notName,
  }) async {
    await t.tap(byKey('home-settings'));
    await t.pumpAndSettle();
    expect(under('settings-profile', name), findsOneWidget);
    expect(under('settings-profile', tag), findsOneWidget);
    expect(find.textContaining(notName), findsNothing, reason: 'stale profile');
    await t.tap(byKey('settings-account'));
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: byKey('account-email'),
        matching: find.text(email),
        matchRoot: true,
      ),
      findsOneWidget,
    );
    await t.pageBack();
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
  }

  /// Everyone the phone is announcing online, by the account it joined as.
  List<String?> get announcedAs => [for (final j in presence.live) j.as];
}

void main() {
  testWidgets('heybana signs out and cagilhay signs in on the same phone: '
      'everything is cagilhay\'s, then heybana\'s again', (t) async {
    final o = Owner(t);
    await o.start();

    // heybana uses the app the way the owner did.
    await o.signInAs(heybana);
    expect(o.listed(), {'c-ab', 'c-ac'});
    expect(await o.pickerOffers(), {cagilhay, deniz});
    await o.openAndLeave('c-ac', onlyHeybana);
    await o.expectSettings(
      name: 'Heybana',
      tag: '@heybana',
      email: 'heybana@example.org',
      notName: 'Cagil Hay',
    );
    expect(o.announcedAs, [heybana]);

    await o.signOut();
    await o.signInAs(cagilhay);

    expect(await o.pickerOffers(), {
      heybana,
      deniz,
    }, reason: 'the picker must offer heybana and never cagilhay to herself');
    expect(o.listed(), {
      'c-ab',
      'c-bc',
    }, reason: 'the list must be cagilhay\'s, with none of heybana\'s own');
    expect(find.text(onlyHeybana), findsNothing);
    await o.expectSettings(
      name: 'Cagil Hay',
      tag: '@cagilhay',
      email: 'cagilhay@example.org',
      notName: 'Heybana',
    );
    expect(o.container.read(openConversationProvider), isNull);
    expect(o.announcedAs, [
      cagilhay,
    ], reason: 'online must be joined as cagilhay, and heybana let go of');

    // And back: heybana sees her own data again, not cagilhay's.
    await o.signOut();
    await o.signInAs(heybana);
    expect(await o.pickerOffers(), {cagilhay, deniz});
    expect(o.listed(), {'c-ab', 'c-ac'});
    await o.expectSettings(
      name: 'Heybana',
      tag: '@heybana',
      email: 'heybana@example.org',
      notName: 'Cagil Hay',
    );
    expect(o.container.read(openConversationProvider), isNull);
    expect(o.announcedAs, [heybana]);
  });

  testWidgets('a conversation open when the session changes is not open for '
      'the next account', (t) async {
    final o = Owner(t);
    await o.start();
    await o.signInAs(heybana);
    // The one conversation both are in: only the reset can close it.
    await t.tap(byKey('conversation-c-ab'));
    await t.pumpAndSettle();
    expect(o.container.read(openConversationProvider), 'c-ab');
    expect(o.chat.liveIncoming, ['c-ab as $heybana']);

    // The session goes away under the open screen (another phone took the
    // account, or the token was revoked), and cagilhay signs in.
    final c = o.container;
    final gone = o.auth.signOut();
    await t.pumpAndSettle();
    await gone;
    o.auth.chosen = cagilhay;
    final back = c.read(sessionControllerProvider.notifier).signIn();
    await t.pumpAndSettle();
    await back;

    expect(c.read(currentUserIdProvider), cagilhay);
    expect(c.read(openConversationProvider), isNull);
    expect(
      o.chat.liveIncoming.where((s) => s.endsWith(heybana)),
      isEmpty,
      reason: 'heybana\'s conversation subscription outlived her session',
    );
  });
}
