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
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/service_key.dart';

/// Editing through the real UI, across the seam a unit test cannot reach:
/// hale long-presses her message, picks Edit, changes the text in the
/// composer and sends -- over the real repository and the real edit_message.
/// Ivo, mounted at once with his chat open AND his conversation list on
/// screen, both wired as main.dart wires them, must see the edit arrive live
/// over Realtime: in place in the chat, and in the list preview only when the
/// edited message is the newest. The failure path is real too: the server
/// refuses an edit whose window closed while the member was typing.
///
/// Requires a running local Supabase, the warmup probe, and
/// SUPABASE_TEST_SERVICE_KEY. Accounts hale/ivo are this suite's own
/// (supabase/seed.sql). Run with --concurrency=1 like the rest.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
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
  // Real timers: two live Realtime clients need wall-clock time to settle.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? haleClient;
  SupabaseClient? ivoClient;
  late SupabaseChatRepository hale;
  late Member haleMember;
  late Member ivoMember;
  late String conversationId;

  setUpAll(() async {
    haleClient = await _signedIn('hale@integration.test');
    ivoClient = await _signedIn('ivo@integration.test');
    hale = SupabaseChatRepository(haleClient!);
    haleMember = Member(
      userId: haleClient!.auth.currentUser!.id,
      displayName: 'Hale',
    );
    ivoMember = Member(
      userId: ivoClient!.auth.currentUser!.id,
      displayName: 'Ivo',
    );
    final started = await hale.startDirectConversation(ivoMember.userId);
    conversationId = (started as Ok<String>).value;
  });

  tearDownAll(() async {
    await haleClient?.dispose();
    await ivoClient?.dispose();
  });

  /// Wired the way main.dart wires chat: the real repository. Presence and
  /// push are fakes -- live presence heartbeats never go idle, and neither
  /// is this seam.
  ProviderContainer containerFor(SupabaseClient client, Member member) =>
      ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(client),
          ),
          attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          sessionControllerProvider.overrideWith(() => _SignedIn(member)),
        ],
      );

  Finder pane(String id) => find.byKey(ValueKey('pane-$id'));
  Finder within(String paneId, Finder matching) =>
      find.descendant(of: pane(paneId), matching: matching);

  String textIn(Finder of) => [
    for (final e
        in find.descendant(of: of, matching: find.byType(RichText)).evaluate())
      (e.widget as RichText).text.toPlainText(),
  ].join(' ');

  String bubbleText(String paneId, String id) {
    final f = within(paneId, find.byKey(ValueKey('message-$id')));
    return f.evaluate().isEmpty ? '' : textIn(f);
  }

  String tileText() {
    final f = within('c', find.byKey(ValueKey('conversation-$conversationId')));
    return f.evaluate().isEmpty ? '' : textIn(f);
  }

  // 300 x 100ms = 30 real seconds; a timeout says what each pane held.
  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 300; i++) {
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    fail(
      'never happened: $what\n'
      '  pane a: ${textIn(pane('a'))}\n'
      '  pane b: ${textIn(pane('b'))}\n'
      '  list:   ${tileText()}',
    );
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> edit(WidgetTester t, String id, String body) async {
    await t.longPress(within('a', find.byKey(ValueKey('message-$id'))));
    await settle(t);
    expect(
      find.byKey(const ValueKey('action-edit')),
      findsOneWidget,
      reason: 'the sheet never offered Edit for $id',
    );
    await t.tap(find.byKey(const ValueKey('action-edit')));
    await settle(t);
    expect(within('a', find.byKey(const ValueKey('edit-bar'))), findsOneWidget);
    await t.enterText(
      within('a', find.byKey(const ValueKey('composer-field'))),
      body,
    );
    await t.pump();
  }

  Future<void> save(WidgetTester t) async {
    await t.tap(within('a', find.byKey(const ValueKey('composer-send'))));
    await settle(t);
  }

  /// Mounts hale's chat (pane a), ivo's chat (pane b) and ivo's list (pane
  /// c) over a clean conversation holding two of hale's fresh messages, and
  /// waits until every pane shows them.
  Future<
    ({String stamp, String olderId, String newestId, SupabaseClient service})
  >
  mount(WidgetTester t) async {
    final service = _client(serviceKey());
    addTearDown(service.dispose);

    // Let an earlier test's channels finish leaving before two more join.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await t.runAsync(
      () => service
          .from('messages')
          .delete()
          .eq('conversation_id', conversationId),
    );

    final stamp = '${DateTime.now().microsecondsSinceEpoch}';
    final older = (await t.runAsync(
      () => hale.send(conversationId: conversationId, body: 'older $stamp'),
    ))!;
    final newest = (await t.runAsync(
      () => hale.send(conversationId: conversationId, body: 'newest $stamp'),
    ))!;
    final olderId = (older as Ok<Message>).value.id;
    final newestId = (newest as Ok<Message>).value.id;

    final haleContainer = containerFor(haleClient!, haleMember);
    final ivoContainer = containerFor(ivoClient!, ivoMember);
    await t.runAsync(() => settled(haleContainer));
    await t.runAsync(() => settled(ivoContainer));
    haleContainer.read(openConversationProvider.notifier).open(conversationId);
    ivoContainer.read(openConversationProvider.notifier).open(conversationId);

    Widget scoped(String id, ProviderContainer c, Widget child) => Expanded(
      child: KeyedSubtree(
        key: ValueKey('pane-$id'),
        child: UncontrolledProviderScope(container: c, child: child),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: sisTheme(Brightness.light),
        home: Scaffold(
          // The list gets the full width below the two chats: a third of
          // the test screen is narrower than any phone.
          body: Column(
            children: [
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    scoped(
                      'a',
                      haleContainer,
                      const MessageScreen(title: 'Ivo'),
                    ),
                    scoped(
                      'b',
                      ivoContainer,
                      const MessageScreen(title: 'Hale'),
                    ),
                  ],
                ),
              ),
              scoped('c', ivoContainer, const ConversationList()),
            ],
          ),
        ),
      ),
    );
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      haleContainer.dispose();
      ivoContainer.dispose();
      await t.runAsync(() => haleClient!.removeAllChannels());
      await t.runAsync(() => ivoClient!.removeAllChannels());
    });

    await until(
      t,
      () =>
          bubbleText('a', olderId).contains('older $stamp') &&
          bubbleText('b', olderId).contains('older $stamp') &&
          bubbleText('b', newestId).contains('newest $stamp') &&
          tileText().contains('newest $stamp'),
      'both chats and ivo\'s list to load',
    );
    return (
      stamp: stamp,
      olderId: olderId,
      newestId: newestId,
      service: service,
    );
  }

  testWidgets('editing an older message: in place, live, in both chats; '
      'ivo\'s list preview and order untouched', (t) async {
    final (:stamp, :olderId, :newestId, service: _) = await mount(t);

    await edit(t, olderId, 'older, edited $stamp');
    await save(t);
    await until(
      t,
      () => bubbleText('a', olderId).contains('older, edited $stamp'),
      'hale\'s own screen to show her edit',
    );
    await until(
      t,
      () =>
          bubbleText('b', olderId).contains('older, edited $stamp') &&
          bubbleText('b', olderId).contains('edited'),
      'ivo\'s open chat to show the edit live, marked edited',
    );
    // His list is on the same client and hears the same UPDATE; give it a
    // moment past the chat before judging that it (correctly) did nothing.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await t.pump();
    expect(tileText(), contains('newest $stamp'));
    expect(
      tileText(),
      isNot(contains('older, edited')),
      reason: 'editing an older message must not become the preview',
    );
    expect(
      t.getTopLeft(within('b', find.byKey(ValueKey('message-$olderId')))).dy,
      lessThan(
        t.getTopLeft(within('b', find.byKey(ValueKey('message-$newestId')))).dy,
      ),
      reason: 'the edited message stays in its place, above the newer one',
    );
  });

  testWidgets('editing the newest message: ivo\'s open chat and his list '
      'preview both follow, live', (t) async {
    final (:stamp, olderId: _, :newestId, service: _) = await mount(t);

    await edit(t, newestId, 'newest, edited $stamp');
    await save(t);
    await until(
      t,
      () => bubbleText('b', newestId).contains('newest, edited $stamp'),
      'ivo\'s open chat to show the newest message edited',
    );
    await until(
      t,
      () => tileText().contains('newest, edited $stamp'),
      'ivo\'s list preview to follow the edit of the newest message',
    );
  });

  testWidgets('a refused edit -- the window closed while hale typed -- shows '
      'why and changes nothing on either side', (t) async {
    final (:stamp, olderId: _, :newestId, :service) = await mount(t);

    await edit(t, newestId, 'too late $stamp');
    await t.runAsync(
      () => service
          .from('messages')
          .update({
            'created_at': DateTime.now()
                .toUtc()
                .subtract(const Duration(hours: 7))
                .toIso8601String(),
          })
          .eq('id', newestId),
    );
    await save(t);
    await until(
      t,
      () => find
          .textContaining(const DeniedFailure().message)
          .evaluate()
          .isNotEmpty,
      'hale to be told the edit was refused',
    );
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await t.pump();
    for (final p in ['a', 'b']) {
      expect(bubbleText(p, newestId), contains('newest $stamp'));
      expect(bubbleText(p, newestId), isNot(contains('too late')));
      expect(bubbleText(p, newestId), isNot(contains('edited')));
    }
    final row = await t.runAsync(
      () => service
          .from('messages')
          .select('body, edited_at')
          .eq('id', newestId)
          .single(),
    );
    expect(row!['body'], 'newest $stamp');
    expect(row['edited_at'], isNull);
  });
}
