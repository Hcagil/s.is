@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/service_key.dart';

/// Two members' message screens, mounted at once over the real repository,
/// exercising the seam a unit test cannot: A deletes her own message through
/// the actual long-press -> sheet -> confirm flow, and B's OPEN screen must
/// see the result arrive live over Realtime -- vanished within the hour,
/// a placeholder afterwards.
///
/// Requires `docker compose run --rm supabase start`. Uses opal and russ
/// (created here, password sign-in); run with --concurrency=1 like the rest
/// of the suite, after test/integration/realtime_warmup_test.dart.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
// The service_role key: the only way from a Dart client to backdate
// created_at, which every insert grant withholds from a member on purpose.
// Equivalent to updating the row "as postgres" the way the pgTAP suite does.
const _password = 'integration-password';

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

void main() {
  // Real timers, not the fake clock `TestWidgetsFlutterBinding.
  // ensureInitialized()` installs: two real, live Realtime subscriptions
  // and a real delete round trip need actual wall-clock time to settle, or
  // whatever retry/backoff timer they are waiting on never fires.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? opalClient;
  SupabaseClient? russClient;
  late SupabaseChatRepository opal;
  late Member opalMember;
  late Member russMember;
  late String conversationId;

  setUpAll(() async {
    opalClient = await _signedIn('opal@integration.test');
    russClient = await _signedIn('russ@integration.test');
    opal = SupabaseChatRepository(opalClient!);
    opalMember = Member(
      userId: opalClient!.auth.currentUser!.id,
      displayName: 'Opal',
    );
    russMember = Member(
      userId: russClient!.auth.currentUser!.id,
      displayName: 'Russ',
    );

    final started = await opal.startDirectConversation(russMember.userId);
    expect(started, isA<Ok<String>>());
    conversationId = (started as Ok<String>).value;
  });

  tearDownAll(() async {
    await opalClient?.dispose();
    await russClient?.dispose();
  });

  /// One member's message screen, wired the way `main.dart` wires it for
  /// the chat repository under test. Presence is a fake here on purpose:
  /// two REAL presence channels, one per side, never go idle (heartbeats),
  /// which starves `pumpAndSettle` and is not what this seam is about
  /// anyway -- only auth (no local Google sign-in) is a fake for the same
  /// reason as every other seam test.
  ProviderContainer containerFor(SupabaseClient client, Member member) =>
      ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(client),
          ),
          attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(() => _SignedIn(member)),
        ],
      );

  // 300 x 100ms = 30 real seconds. On timeout the failure says what the
  // screen, each pane's message markers and (via [explain]) the database and
  // controller held, so a CI-only failure explains itself.
  Future<void> until(
    WidgetTester t,
    bool Function() ok,
    String what, {
    Future<String> Function()? explain,
  }) async {
    for (var i = 0; i < 300; i++) {
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    // Explain a timeout instead of only reporting it: what is on screen (a
    // refused delete leaves its reason in a SnackBar) and which message
    // markers each pane holds.
    final shown = [
      for (final e in find.byType(Text, skipOffstage: false).evaluate())
        if ((e.widget as Text).data case final text? when text.isNotEmpty) text,
    ];
    String markers(String paneId) => [
      for (final e
          in find
              .descendant(
                of: find.byKey(ValueKey('pane-$paneId')),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      RegExp(r'^(message|vanish|deleted)-')
                          .hasMatch((w.key! as ValueKey<String>).value),
                  skipOffstage: false,
                ),
              )
              .evaluate())
        (e.widget.key! as ValueKey<String>).value,
    ].join(', ');
    final more = explain == null ? '' : await t.runAsync(explain) ?? '';
    fail(
      'never happened: $what\n'
      '$more'
      '  on screen: $shown\n'
      '  pane a: ${markers('a')}\n'
      '  pane b: ${markers('b')}',
    );
  }

  // `pumpAndSettle()` waits for the WHOLE app to stop scheduling frames --
  // with two real, live presence/Realtime subscriptions attached, that
  // moment never comes, and it hangs forever. A local sheet or dialog
  // transition settles in well under this, so a couple of fixed pumps
  // stand in for it.
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  /// [id]'s pane-scoped subtree, so the same message's key -- identical on
  /// both sides, since it is the SAME row -- never resolves ambiguously.
  Finder pane(String id) => find.byKey(ValueKey('pane-$id'));
  Finder within(String paneId, Finder matching) =>
      find.descendant(of: pane(paneId), matching: matching);

  /// Like [within], but also finds what is laid out at zero size: a vanished
  /// message ends its animation at zero height, which the default finders
  /// treat as offstage -- so a fast machine catches it mid-animation and a
  /// slow one (CI) never does. `find.descendant` applies its own
  /// skipOffstage, so it has to be turned off there, not only inside.
  Finder anywhereWithin(String paneId, Finder matching) => find.descendant(
    of: pane(paneId),
    matching: matching,
    skipOffstage: false,
  );

  testWidgets('A deletes her own message through the sheet; B\'s open screen '
      'sees it vanish, and a backdated one become a placeholder', (t) async {
    // Written directly with the service key, bypassing RLS the way a
    // trusted backend job would -- and the way the pgTAP suite backdates
    // created_at "as postgres": no client insert grant ever allows it.
    final service = _client(serviceKey());
    addTearDown(service.dispose);

    // A moment for a prior integration file's own Realtime channels to
    // finish releasing server-side before this one joins two more: back to
    // back, that handover is occasionally still in flight.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));

    // A clean conversation: opal and russ are fixed seed accounts, reused
    // by every run of this test, and their history otherwise only grows --
    // more rows to load and render each time, on top of an earlier run's
    // own placeholder text still matching a loose `find.text` search.
    await t.runAsync(
      () => service
          .from('messages')
          .delete()
          .eq('conversation_id', conversationId),
    );

    final recentBody = 'seam recent ${DateTime.now().microsecondsSinceEpoch}';
    final oldBody = 'seam old ${DateTime.now().microsecondsSinceEpoch}';

    // Every direct repository/PostgREST call here is wrapped in runAsync:
    // called plainly inside testWidgets, real network I/O never completes,
    // because the fake clock this binding installs never advances on its
    // own to run whatever retry/backoff timer the SDK is waiting on.
    final recent = await t.runAsync(
      () => opal.send(conversationId: conversationId, body: recentBody),
    );
    final old = await t.runAsync(
      () => opal.send(conversationId: conversationId, body: oldBody),
    );
    expect(recent, isA<Ok<Message>>());
    expect(old, isA<Ok<Message>>());
    final recentMessage = (recent! as Ok<Message>).value;
    final oldMessage = (old! as Ok<Message>).value;
    // Two hours old: still inside the 6-hour delete window, but past the
    // 1-hour vanish threshold, so this one must become a placeholder.
    // `.toUtc()` matters: under the suite's non-UTC TZ, a naive local
    // string here would be read back by Postgres as UTC, landing hours in
    // the future rather than in the past.
    await t.runAsync(
      () => service
          .from('messages')
          .update({
            'created_at': DateTime.now()
                .toUtc()
                .subtract(const Duration(hours: 2))
                .toIso8601String(),
          })
          .eq('id', oldMessage.id),
    );

    final opalContainer = containerFor(opalClient!, opalMember);
    final russContainer = containerFor(russClient!, russMember);
    await t.runAsync(() => settled(opalContainer));
    await t.runAsync(() => settled(russContainer));
    opalContainer.read(openConversationProvider.notifier).open(conversationId);
    russContainer.read(openConversationProvider.notifier).open(conversationId);

    await t.pumpWidget(
      MaterialApp(
        theme: sisTheme(Brightness.light),
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('pane-a'),
                  child: UncontrolledProviderScope(
                    container: opalContainer,
                    child: const MessageScreen(title: 'Russ'),
                  ),
                ),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('pane-b'),
                  child: UncontrolledProviderScope(
                    container: russContainer,
                    child: const MessageScreen(title: 'Opal'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await until(
      t,
      () =>
          within(
            'a',
            find.byKey(ValueKey('message-${oldMessage.id}')),
          ).evaluate().isNotEmpty &&
          within(
            'b',
            find.byKey(ValueKey('message-${oldMessage.id}')),
          ).evaluate().isNotEmpty,
      'both screens to load the seeded messages',
    );

    // A deletes the recent message, through the real UI: long-press,
    // the sheet, the confirm dialog.
    await t.longPress(
      within('a', find.byKey(ValueKey('message-${recentMessage.id}'))),
    );
    await settle(t);
    await t.tap(find.byKey(const ValueKey('action-delete')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('delete-confirm')));
    await settle(t);

    // A's own screen updates at once, locally, the moment her repository
    // call resolves -- proof the delete itself went through, independent
    // of whatever Realtime then does to tell B.
    await until(
      t,
      () => anywhereWithin(
        'a',
        find.byKey(ValueKey('vanish-${recentMessage.id}'), skipOffstage: false),
      ).evaluate().isNotEmpty,
      'A\'s own screen to update after her delete',
      // Server or app? The row in the database, and A's controller state.
      explain: () async {
        final row = await service
            .from('messages')
            .select('deleted, deleted_at')
            .eq('id', recentMessage.id)
            .maybeSingle();
        final state = opalContainer.read(messagesProvider);
        final mine = state.value
            ?.where((m) => m.id == recentMessage.id)
            .firstOrNull;
        return '  db row: $row\n'
            '  controller: ${state.runtimeType} '
            'deletion=${mine?.deletion} present=${mine != null}\n';
      },
    );

    // B's OPEN screen sees it vanish, live, without any action of his own.
    await until(
      t,
      () => anywhereWithin(
        'b',
        find.byKey(ValueKey('vanish-${recentMessage.id}'), skipOffstage: false),
      ).evaluate().isNotEmpty,
      'B\'s screen to see the recent message vanish',
    );

    // The backdated message: over an hour old, so deleting it leaves a
    // placeholder rather than nothing.
    await t.longPress(
      within('a', find.byKey(ValueKey('message-${oldMessage.id}'))),
    );
    await settle(t);
    expect(
      find.byKey(const ValueKey('action-delete')),
      findsOneWidget,
      reason: 'the sheet never opened for the second message',
    );
    await t.tap(find.byKey(const ValueKey('action-delete')));
    await settle(t);
    expect(
      find.byKey(const ValueKey('delete-confirm')),
      findsOneWidget,
      reason: 'the confirm dialog never opened for the second message',
    );
    await t.tap(find.byKey(const ValueKey('delete-confirm')));
    await settle(t);

    await until(
      t,
      () => within(
        'a',
        find.byKey(ValueKey('deleted-${oldMessage.id}')),
      ).evaluate().isNotEmpty,
      'A\'s own screen to show the old message as a placeholder',
    );

    await until(
      t,
      () => within(
        'b',
        find.byKey(ValueKey('deleted-${oldMessage.id}')),
      ).evaluate().isNotEmpty,
      'B\'s screen to show the old message as a placeholder',
    );
    // Scoped to this run's own message: the conversation is a fixed, reused
    // seed pair, and an earlier run's own placeholder can still be sitting
    // in the same history.
    expect(
      find.descendant(
        of: within('b', find.byKey(ValueKey('deleted-${oldMessage.id}'))),
        matching: find.text('This message was deleted'),
      ),
      findsOneWidget,
    );

    await t.pumpWidget(const SizedBox());
    opalContainer.dispose();
    russContainer.dispose();
    await t.runAsync(() => opalClient!.removeAllChannels());
    await t.runAsync(() => russClient!.removeAllChannels());
    await t.runAsync(() => opalClient!.realtime.disconnect());
    await t.runAsync(() => russClient!.realtime.disconnect());
    // No pump(61 s) to flush timers, as the fake-clock suites end with:
    // under this live binding it is a real minute of waiting, and a live
    // test has no pending fake timers to flush.
  });
}
