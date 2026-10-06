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
import 'package:sis/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/service_key.dart';

/// The Forward picker's multi-select over the real repository: reid opens
/// his chat with beth, forwards one message through the actual tap -> card
/// -> Forward -> tick two chats -> "Send (2)" flow, and each ticked chat --
/// read back by cora, a member of both -- holds exactly one forwarded copy;
/// the chat he forwarded from gains none.
///
/// Requires `docker compose run --rm supabase start`. Uses reid, beth and
/// cora (supabase/seed.sql), like reply_forward_seam_test.dart; run with
/// --concurrency=1 like the rest of the suite.
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
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? reidClient;
  SupabaseClient? bethClient;
  SupabaseClient? coraClient;
  late SupabaseChatRepository reid;
  late SupabaseChatRepository cora;
  late Member reidMember;
  late String c1; // reid+beth: forwarded from
  late String c2; // reid+cora: ticked
  late String c3; // a group of all three: ticked

  setUpAll(() async {
    reidClient = await _signedIn('reid@integration.test');
    bethClient = await _signedIn('beth@integration.test');
    coraClient = await _signedIn('cora@integration.test');
    reid = SupabaseChatRepository(reidClient!);
    cora = SupabaseChatRepository(coraClient!);
    reidMember = Member(
      userId: reidClient!.auth.currentUser!.id,
      displayName: 'Reid',
    );
    await findByTag(reidClient!, [bethClient!, coraClient!]);
    final beth = bethClient!.auth.currentUser!.id;
    final coraId = coraClient!.auth.currentUser!.id;
    c1 = ((await reid.startDirectConversation(beth)) as Ok<String>).value;
    c2 = ((await reid.startDirectConversation(coraId)) as Ok<String>).value;
    c3 = ((await reid.startGroupConversation(
      title: 'FM ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [beth, coraId],
    )) as Ok<String>).value;
  });

  tearDownAll(() async {
    await reidClient?.dispose();
    await bethClient?.dispose();
    await coraClient?.dispose();
  });

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 600; i++) {
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    fail('never happened: $what');
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('two chats ticked in the picker each get one forwarded copy', (
    t,
  ) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    final service = _client(serviceKey());
    addTearDown(service.dispose);
    for (final c in [c1, c2]) {
      await t.runAsync(
        () => service.from('messages').delete().eq('conversation_id', c),
      );
    }

    final body = 'multi forward ${DateTime.now().microsecondsSinceEpoch}';
    final sent = await t.runAsync(
      () => reid.send(id: randomMessageId(), conversationId: c1, body: body),
    );
    final original = (sent! as Ok<Message>).value;

    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(reid),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(reidMember)),
      ],
    );
    await t.runAsync(() => settled(container));
    container.read(openConversationProvider.notifier).open(c1);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: sisTheme(Brightness.light),
          home: const MessageScreen(title: 'Beth'),
        ),
      ),
    );

    final bubble = find.byKey(ValueKey('message-${original.id}'));
    await until(t, () => bubble.evaluate().isNotEmpty, 'the message');
    await t.longPress(bubble);
    await until(
      t,
      () => find.byKey(const ValueKey('menu-forward')).evaluate().isNotEmpty,
      'the card',
    );
    await t.tap(find.byKey(const ValueKey('menu-forward')));
    await settle(t);

    final anyTarget = find.byWidgetPredicate((w) {
      final k = w.key;
      return k is ValueKey<String> &&
          RegExp(r'^forward-[0-9a-f-]{36}$').hasMatch(k.value);
    });
    await until(t, () => anyTarget.evaluate().isNotEmpty, 'the picker');
    for (final c in [c2, c3]) {
      final target = find.byKey(ValueKey('forward-$c'));
      await t.scrollUntilVisible(
        target,
        100,
        scrollable: find
            .ancestor(of: anyTarget.first, matching: find.byType(Scrollable))
            .first,
      );
      // scrollUntilVisible returns with the lazily built list one frame
      // stale (rows of different heights): the row can still sit under the
      // Send bar. Reid taps what he sees once it has landed.
      await until(
        t,
        () => target.hitTestable().evaluate().isNotEmpty,
        'the picked chat to come to rest above the Send bar',
      );
      await t.tap(target);
      await settle(t);
    }
    expect(find.text('Send (2)'), findsOneWidget);
    expect(find.byKey(const ValueKey('forward-chosen')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('forward-send')));
    await settle(t);

    Future<List<Message>> copies(String c) async {
      final r = await cora.messages(c);
      return [
        for (final m in (r as Ok<List<Message>>).value)
          if (m.body == body && m.forwarded) m,
      ];
    }

    for (final c in [c2, c3]) {
      var found = <Message>[];
      for (var i = 0; i < 100 && found.isEmpty; i++) {
        found = (await t.runAsync(() => copies(c)))!;
        if (found.isEmpty) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
        }
      }
      expect(found, hasLength(1), reason: 'forwarded copies in $c');
    }
    final inC1 = await t.runAsync(
      () => service
          .from('messages')
          .select('id')
          .eq('conversation_id', c1)
          .eq('body', body),
    );
    expect(inC1, hasLength(1), reason: 'the source chat gained a copy');

    await t.pumpWidget(const SizedBox());
    container.dispose();
    await t.runAsync(() => reidClient!.removeAllChannels());
    await t.runAsync(() => reidClient!.realtime.disconnect());
  });
}
