@Tags(['integration'])
library;

import 'dart:convert';
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
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/service_key.dart';

/// Two members' message screens, mounted at once over the real repository:
/// reid replies to a message through the actual long-press -> sheet -> type
/// -> send flow and sees the quote on his own screen; he then forwards a
/// real photo, sent moments before, to a SECOND conversation through the
/// actual long-press -> forward sheet -> pick -> send flow, and cora's own,
/// separately mounted screen over that second conversation must show it
/// arrive, marked Forwarded, with a photo that actually loads for her.
///
/// Requires `docker compose run --rm supabase start`. Uses reid, beth and
/// cora (supabase/seed.sql; password sign-in exists only locally); run with
/// --concurrency=1 like the rest of the suite, after
/// test/integration/realtime_warmup_test.dart.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real 1x1 PNG: the bucket checks the mime type against real bytes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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
  // Real timers: two real, live Realtime subscriptions and real round trips
  // need actual wall-clock time to settle, or a retry/backoff timer never
  // fires under the fake clock the default binding installs.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? reidClient;
  SupabaseClient? bethClient;
  SupabaseClient? coraClient;
  late SupabaseChatRepository reid;
  late Member reidMember;
  late Member bethMember;
  late Member coraMember;
  late String c1; // reid+beth: the source conversation
  late String c2; // reid+cora: the forward target

  setUpAll(() async {
    reidClient = await _signedIn('reid@integration.test');
    bethClient = await _signedIn('beth@integration.test');
    coraClient = await _signedIn('cora@integration.test');
    reid = SupabaseChatRepository(reidClient!);
    reidMember = Member(
      userId: reidClient!.auth.currentUser!.id,
      displayName: 'Reid',
    );
    bethMember = Member(
      userId: bethClient!.auth.currentUser!.id,
      displayName: 'Beth',
    );
    coraMember = Member(
      userId: coraClient!.auth.currentUser!.id,
      displayName: 'Cora',
    );

    final s1 = await reid.startDirectConversation(bethMember.userId);
    c1 = (s1 as Ok<String>).value;
    final s2 = await reid.startDirectConversation(coraMember.userId);
    c2 = (s2 as Ok<String>).value;
  });

  tearDownAll(() async {
    await reidClient?.dispose();
    await bethClient?.dispose();
    await coraClient?.dispose();
  });

  /// One member's message screen, wired the way `main.dart` wires it for
  /// the chat repository under test. Auth is a fake (no local Google
  /// sign-in to run against); presence is a fake for the same reason as
  /// every other seam test -- a real presence channel never goes idle and
  /// starves pumpAndSettle.
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

  // 600 x 100ms = 60 real seconds, matching message_delete_seam_test.dart's
  // own budget: late in a full `flutter test test/integration` run, behind
  // dozens of other real-network suites, a real round trip (here,
  // conversationListProvider's own conversations() read for the forward
  // picker) can take much longer than it does run alone.
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

  Finder pane(String id) => find.byKey(ValueKey('pane-$id'));
  Finder within(String paneId, Finder matching) =>
      find.descendant(of: pane(paneId), matching: matching);

  testWidgets(
    'reid replies through the UI and sees the quote; forwarding a photo '
    'through the UI lands it, marked Forwarded, readable by cora',
    (t) async {
      final service = _client(serviceKey());
      addTearDown(service.dispose);

      // A moment for a prior file's own Realtime channels to finish
      // releasing server-side before this one joins two more.
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));

      // Clean, reused, seed conversations: only this run's own rows should
      // be on screen.
      await t.runAsync(
        () => service.from('messages').delete().eq('conversation_id', c1),
      );
      await t.runAsync(
        () => service.from('messages').delete().eq('conversation_id', c2),
      );

      final quotedBody = 'seam quoted ${DateTime.now().microsecondsSinceEpoch}';
      final quoted = await t.runAsync(
        () => reid.send(conversationId: c1, body: quotedBody),
      );
      expect(quoted, isA<Ok<Message>>());
      final quotedMessage = (quoted! as Ok<Message>).value;

      final photo = await t.runAsync(
        () => reid.sendImage(
          conversationId: c1,
          image: PickedImage(
            bytes: _png,
            contentType: 'image/png',
            extension: 'png',
          ),
        ),
      );
      expect(photo, isA<Ok<Message>>());
      final photoMessage = (photo! as Ok<Message>).value;

      final reidContainer = containerFor(reidClient!, reidMember);
      final coraContainer = containerFor(coraClient!, coraMember);
      await t.runAsync(() => settled(reidContainer));
      await t.runAsync(() => settled(coraContainer));
      reidContainer.read(openConversationProvider.notifier).open(c1);
      coraContainer.read(openConversationProvider.notifier).open(c2);

      // Each pane gets its OWN MaterialApp -- and so its own Navigator and
      // route overlay -- nested INSIDE that pane's own ProviderScope, the
      // way one real device hosts exactly one app over one account. A
      // single MaterialApp shared by both panes would push every route
      // (the forward sheet included) into ONE overlay that sits above both
      // panes' ProviderScopes -- fatal for the forward sheet, a
      // ConsumerStatefulWidget that reads conversationListProvider at build
      // time, unlike the plain long-press sheet reused from v0.10A.
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('pane-a'),
                  child: UncontrolledProviderScope(
                    container: reidContainer,
                    child: MaterialApp(
                      theme: sisTheme(Brightness.light),
                      home: const MessageScreen(title: 'Beth'),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('pane-b'),
                  child: UncontrolledProviderScope(
                    container: coraContainer,
                    child: MaterialApp(
                      theme: sisTheme(Brightness.light),
                      home: const MessageScreen(title: 'Reid'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      await until(
        t,
        () => within(
          'a',
          find.byKey(ValueKey('message-${photoMessage.id}')),
        ).evaluate().isNotEmpty,
        'reid\'s screen to load the seeded text and photo messages',
      );

      // -- forward, through the real UI (done FIRST: a clean screen, no
      // prior keyboard/focus/scroll state to disturb the long-press) -------
      final photoFinder = within(
        'a',
        find.byKey(ValueKey('message-${photoMessage.id}')),
      );
      await t.longPress(photoFinder);
      await settle(t);
      await t.tap(find.byKey(const ValueKey('action-forward')));
      await settle(t);
      // The picker's checkboxes come from a real conversationListProvider
      // read (conversations()), not from anything already on screen -- a
      // fixed settle() is not a bound on a real network round trip, only on
      // a local sheet/dialog transition. Waited for explicitly, the same
      // way every other real-data appearance in this file is.
      await until(
        t,
        () => find.byKey(ValueKey('forward-$c2')).evaluate().isNotEmpty,
        'the forward picker to load the target conversation',
      );
      expect(find.byKey(ValueKey('forward-$c1')), findsNothing);

      await t.tap(find.byKey(ValueKey('forward-$c2')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('forward-send')));
      await settle(t);
      // Scoped to pane a: cora's own pane may by now also show a
      // "Forwarded" label on the arrived copy, and the two must not be
      // confused with each other.
      expect(within('a', find.text('Forwarded')), findsOneWidget);
      // The SnackBar sits over the composer; let it dismiss before the
      // reply flow taps there.
      await until(
        t,
        () => within('a', find.text('Forwarded')).evaluate().isEmpty,
        'reid\'s "Forwarded" snackbar to dismiss',
      );

      // -- reply, through the real UI ---------------------------------------
      final quotedFinder = within(
        'a',
        find.byKey(ValueKey('message-${quotedMessage.id}')),
      );
      await t.longPress(quotedFinder);
      await settle(t);
      await t.tap(find.byKey(const ValueKey('action-reply')));
      await settle(t);
      expect(
        within('a', find.byKey(const ValueKey('reply-bar'))),
        findsOneWidget,
      );

      await t.enterText(
        within('a', find.byKey(const ValueKey('composer-field'))),
        'sounds good',
      );
      await t.tap(within('a', find.byKey(const ValueKey('composer-send'))));
      await settle(t);

      await until(
        t,
        () => within('a', find.text('sounds good')).evaluate().isNotEmpty,
        'reid\'s own reply to appear on his screen',
      );
      final quoteFinder = within(
        'a',
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.key is ValueKey &&
              (w.key! as ValueKey).value.toString().startsWith('quote-'),
        ),
      );
      await until(
        t,
        () => quoteFinder.evaluate().isNotEmpty,
        'the new bubble to show a quote of the original message',
      );
      expect(
        find.descendant(of: quoteFinder, matching: find.text(quotedBody)),
        findsOneWidget,
        reason: 'the quote must carry the original message\'s own text',
      );

      // -- cora's own, separately mounted screen sees it arrive live -------
      await until(
        t,
        () => within(
          'b',
          find.byWidgetPredicate((w) {
            final k = w.key;
            return k is ValueKey && k.value.toString().startsWith('forwarded-');
          }),
        ).evaluate().isNotEmpty,
        'cora\'s screen to show the forwarded message, marked Forwarded',
      );
      expect(within('b', find.text('Forwarded')), findsOneWidget);

      // The photo must actually load for cora: readable in the conversation
      // it was forwarded into, never an error placeholder.
      await until(
        t,
        () => within(
          'b',
          find.byKey(const ValueKey('attachment-image')),
        ).evaluate().isNotEmpty,
        'the forwarded photo to load on cora\'s screen',
      );
      expect(within('b', find.text('Image unavailable')), findsNothing);

      await t.pumpWidget(const SizedBox());
      reidContainer.dispose();
      coraContainer.dispose();
      await t.runAsync(() => reidClient!.removeAllChannels());
      await t.runAsync(() => coraClient!.removeAllChannels());
      await t.runAsync(() => reidClient!.realtime.disconnect());
      await t.runAsync(() => coraClient!.realtime.disconnect());
      // No pump(61 s) to flush timers, as the fake-clock suites end with:
      // under this live binding it is a real minute of waiting, and a live
      // test has no pending fake timers to flush.
    },
  );
}
