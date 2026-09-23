// Every per-account provider follows currentUserIdProvider.
//
// Written from the contract of the account-switch fix: when the signed-in
// member changes, openConversationProvider goes back to null and every
// provider holding one account's data is rebuilt for the next account.
//
// Each provider is kept alive by a listener throughout, the way a screen
// that stays mounted keeps it alive, so a provider that is merely disposed
// and re-created by accident cannot pass. The account changes through the
// real SessionController, driven by an auth fake that switches the ONE
// session every repository fake answers for — so a provider that kept the
// last account's answer shows that account's data, exactly as on the phone.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';

import '../../support/account_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

class Phone {
  Phone() : backend = onePhoneTwoAccounts() {
    backend.signedIn = heybana; // a persisted session from before
    auth = SwitchingAuth(backend);
    chat = SessionChat(backend);
    profile = SessionProfile(backend);
    presence = SessionPresence(backend);
    c = ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(auth),
        chatRepositoryProvider.overrideWithValue(chat),
        profileRepositoryProvider.overrideWithValue(profile),
        presenceRepositoryProvider.overrideWithValue(presence),
      ],
    );
    // The session gate watches both for as long as the app runs.
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(ownProfileProvider, (_, _) {});
  }

  final Backend backend;
  late final SwitchingAuth auth;
  late final SessionChat chat;
  late final SessionProfile profile;
  late final SessionPresence presence;
  late final ProviderContainer c;
}

/// Lets every fake hop and every reaction run, without moving the clock far
/// enough for a typing linger to notice.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(Duration.zero);
  }
}

/// Awaits [call] while pumping: the fakes' hops are timers on the test
/// clock, which only moves when pumped.
Future<void> run(WidgetTester t, Future<void> call) async {
  var done = false;
  call.whenComplete(() => done = true).ignore();
  for (var i = 0; i < 200 && !done; i++) {
    await t.pump(Duration.zero);
  }
  expect(done, isTrue, reason: 'the call never completed');
  await call;
  await settle(t);
}

Future<Phone> signedInAsHeybana(WidgetTester t) async {
  final p = Phone();
  await settle(t);
  expect(p.c.read(currentUserIdProvider), heybana, reason: 'precondition');
  return p;
}

/// Sign out, then sign in as [who] in the same app session.
Future<void> switchTo(WidgetTester t, Phone p, String who) async {
  await run(t, p.c.read(sessionControllerProvider.notifier).signOut());
  expect(p.c.read(currentUserIdProvider), isNull, reason: 'still signed in');
  p.auth.chosen = who;
  await run(t, p.c.read(sessionControllerProvider.notifier).signIn());
  expect(p.c.read(currentUserIdProvider), who, reason: 'switch failed');
}

Set<String> ids<T>(Iterable<T> xs, String Function(T) id) => {
  for (final x in xs) id(x),
};

void main() {
  group('currentUserIdProvider', () {
    testWidgets('is the allowed member, null signed out, null when denied', (
      t,
    ) async {
      final p = await signedInAsHeybana(t);
      final seen = <String?>[];
      p.c.listen(currentUserIdProvider, (_, next) => seen.add(next));

      await switchTo(t, p, cagilhay);
      expect(seen, [null, cagilhay]);

      await run(t, p.c.read(sessionControllerProvider.notifier).signOut());
      p.auth.chosen = stranger;
      await run(t, p.c.read(sessionControllerProvider.notifier).signIn());
      expect(p.c.read(sessionControllerProvider).value, isA<Denied>());
      expect(p.c.read(currentUserIdProvider), isNull);
    });
  });

  testWidgets('a recheck that settles on the same member changes nothing', (
    t,
  ) async {
    final p = await signedInAsHeybana(t);
    final ids = <String?>[];
    p.c.listen(currentUserIdProvider, (_, next) => ids.add(next));
    p.presence.elsewhere = {deniz};
    p.c.listen(conversationListProvider, (_, _) {});
    p.c.listen(openConversationProvider, (_, _) {});
    p.c.listen(onlineMembersProvider, (_, _) {});
    p.c.listen(typingProvider, (_, _) {});
    p.c.read(openConversationProvider.notifier).open('c-ab');
    await settle(t);
    final listReads = p.chat.calls.where((c) => c.startsWith('conversations'));
    final readsBefore = listReads.length;
    final joinsBefore = [...p.presence.joins];
    final typingBefore = [...p.presence.typingChannels];
    expect(p.presence.live.map((j) => j.as), [heybana], reason: 'setup');
    expect(typingBefore.single.closed, isFalse, reason: 'setup');

    // The session is checked again (Retry) and is still heybana's.
    await run(t, p.c.read(sessionControllerProvider.notifier).retry());
    expect(p.c.read(sessionControllerProvider).value, isA<Allowed>());

    expect(ids, isEmpty, reason: 'the account "changed" to itself');
    expect(p.c.read(openConversationProvider), 'c-ab');
    expect(listReads.length, readsBefore, reason: 'the list was re-read');
    expect(p.presence.joins, joinsBefore, reason: 'presence rejoined');
    expect(p.presence.live.map((j) => j.as), [heybana]);
    expect(p.presence.typingChannels, typingBefore);
    expect(typingBefore.single.closed, isFalse, reason: 'typing torn down');
    await t.pump(typingLinger * 2);
  });

  testWidgets('openConversationProvider goes back to null', (t) async {
    final p = await signedInAsHeybana(t);
    p.c.listen(openConversationProvider, (_, _) {});
    // A conversation both of them are in, so only the reset can close it:
    // cagilhay could legitimately read it.
    p.c.read(openConversationProvider.notifier).open('c-ab');
    expect(p.c.read(openConversationProvider), 'c-ab');

    await switchTo(t, p, cagilhay);
    expect(p.c.read(openConversationProvider), isNull);

    await switchTo(t, p, heybana);
    expect(p.c.read(openConversationProvider), isNull, reason: 'reopened');
  });

  group('conversationListProvider', () {
    testWidgets("is the new account's list, and live only for it", (t) async {
      final p = await signedInAsHeybana(t);
      p.c.listen(conversationListProvider, (_, _) {});
      await settle(t);
      Set<String> listed() =>
          ids(p.c.read(conversationListProvider).requireValue, (c) => c.id);
      expect(listed(), {'c-ab', 'c-ac'});

      await switchTo(t, p, cagilhay);
      expect(listed(), {'c-ab', 'c-bc'});
      expect(p.chat.liveAllAs, [
        cagilhay,
      ], reason: 'the list-wide subscription must be the new account\'s only');

      await switchTo(t, p, heybana);
      expect(listed(), {'c-ab', 'c-ac'});
      expect(p.chat.liveAllAs, [heybana]);
    });

    testWidgets('an answer for the old account that lands after the switch is '
        'not shown', (t) async {
      final p = await signedInAsHeybana(t);
      p.chat.holdList();
      p.c.listen(conversationListProvider, (_, _) {});
      await settle(t);
      expect(p.chat.calls, contains('conversations as $heybana'));

      await switchTo(t, p, cagilhay);
      p.chat.releaseList();
      await settle(t);

      expect(
        ids(p.c.read(conversationListProvider).requireValue, (c) => c.id),
        {'c-ab', 'c-bc'},
      );
    });
  });

  testWidgets('membersProvider is "everyone else" for the new account', (
    t,
  ) async {
    final p = await signedInAsHeybana(t);
    p.c.listen(membersProvider, (_, _) {});
    await settle(t);
    Set<String> members() =>
        ids(p.c.read(membersProvider).requireValue, (m) => m.userId);
    expect(members(), {cagilhay, deniz});

    await switchTo(t, p, cagilhay);
    expect(members(), {heybana, deniz});

    await switchTo(t, p, heybana);
    expect(members(), {cagilhay, deniz});
  });

  testWidgets("ownProfileProvider is the new account's profile", (t) async {
    final p = await signedInAsHeybana(t);
    await settle(t);
    expect(p.c.read(ownProfileProvider).requireValue.userId, heybana);

    await switchTo(t, p, cagilhay);
    final now = p.c.read(ownProfileProvider).requireValue;
    expect(
      (now.userId, now.displayName, now.tag),
      (cagilhay, 'Cagil Hay', 'cagilhay'),
    );

    await switchTo(t, p, heybana);
    expect(p.c.read(ownProfileProvider).requireValue.userId, heybana);
  });

  testWidgets('onlineMembersProvider rejoins as the new account and lets go '
      'of the old join', (t) async {
    final p = await signedInAsHeybana(t);
    p.presence.elsewhere = {deniz};
    p.c.listen(onlineMembersProvider, (_, _) {});
    await settle(t);
    expect(p.presence.live.map((j) => j.as), [heybana]);
    expect(p.c.read(onlineMembersProvider), {heybana, deniz});

    await switchTo(t, p, cagilhay);
    expect(p.presence.live.map((j) => j.as), [
      cagilhay,
    ], reason: 'the phone still announces the account that signed out');
    expect(p.c.read(onlineMembersProvider), {cagilhay, deniz});

    await switchTo(t, p, heybana);
    expect(p.presence.live.map((j) => j.as), [heybana]);
    expect(p.c.read(onlineMembersProvider), {heybana, deniz});
  });

  testWidgets('messagesProvider drops the old account\'s conversation', (
    t,
  ) async {
    final p = await signedInAsHeybana(t);
    p.c.listen(messagesProvider, (_, _) {});
    p.c.read(openConversationProvider.notifier).open('c-ac');
    await settle(t);
    expect(p.c.read(messagesProvider).requireValue.map((m) => m.body), [
      onlyHeybana,
    ]);
    expect(p.chat.liveIncoming, ['c-ac as $heybana']);

    await switchTo(t, p, cagilhay);
    expect(p.c.read(messagesProvider).requireValue, isEmpty);
    expect(p.chat.liveIncoming, isEmpty, reason: 'old subscription kept');
  });

  testWidgets('typingProvider closes the old account\'s channel', (t) async {
    final p = await signedInAsHeybana(t);
    p.c.listen(typingProvider, (_, _) {});
    p.c.read(openConversationProvider.notifier).open('c-ab');
    await settle(t);
    final old = p.presence.typingChannels.single;
    expect((old.as, old.conversationId, old.closed), (heybana, 'c-ab', false));
    old.type(deniz);
    await settle(t);
    expect(p.c.read(typingProvider), {deniz});

    await switchTo(t, p, cagilhay);
    expect(old.closed, isTrue, reason: 'still listening as heybana');
    expect(p.presence.typingChannels.where((c) => !c.closed), isEmpty);
    expect(p.c.read(typingProvider), isEmpty);
    await t.pump(typingLinger * 2);
  });

  testWidgets('lastSeenProvider is asked again, as the new account', (t) async {
    final p = await signedInAsHeybana(t);
    p.c.listen(lastSeenProvider(deniz), (_, _) {});
    await settle(t);
    expect(p.c.read(lastSeenProvider(deniz)).requireValue, denizSeen);

    // cagilhay does not share last seen, so the server shows her nobody's.
    await switchTo(t, p, cagilhay);
    expect(p.c.read(lastSeenProvider(deniz)).requireValue, isNull);
    expect(p.presence.calls, contains('lastSeen:$deniz as $cagilhay'));

    await switchTo(t, p, heybana);
    expect(p.c.read(lastSeenProvider(deniz)).requireValue, denizSeen);
  });

  group('attachmentUrlProvider', () {
    const path = 'att/1.jpg';

    testWidgets('is the new account\'s signed URL, asked again on switch', (
      t,
    ) async {
      final p = await signedInAsHeybana(t);
      p.c.listen(attachmentUrlProvider(path), (_, _) {});
      await settle(t);
      expect(
        p.c.read(attachmentUrlProvider(path)).requireValue.toString(),
        contains('as=$heybana'),
      );
      expect(p.chat.calls, contains('attachmentUrl:$path as $heybana'));

      await switchTo(t, p, cagilhay);
      await settle(t);
      expect(
        p.c.read(attachmentUrlProvider(path)).requireValue.toString(),
        contains('as=$cagilhay'),
        reason: 'kept heybana\'s signed URL past the switch',
      );
      expect(p.chat.calls, contains('attachmentUrl:$path as $cagilhay'));
    });

    testWidgets('a recheck of the same account does not ask again', (t) async {
      final p = await signedInAsHeybana(t);
      p.c.listen(attachmentUrlProvider(path), (_, _) {});
      await settle(t);
      final callsBefore = p.chat.calls
          .where((c) => c.startsWith('attachmentUrl:$path'))
          .length;
      expect(callsBefore, 1, reason: 'setup');

      await run(t, p.c.read(sessionControllerProvider.notifier).retry());
      expect(p.c.read(sessionControllerProvider).value, isA<Allowed>());

      expect(
        p.chat.calls.where((c) => c.startsWith('attachmentUrl:$path')).length,
        callsBefore,
        reason: 'asked the repository again for the same account',
      );
    });
  });
}
