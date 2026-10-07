/// Seam test for adding members and controlling history visibility.
/// Reuses the same accounts and helper logic from group_settings_seam_test.dart.
/// Runs against the local Supabase stack with the integration service key.

@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_group_settings_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/add_members_page.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/l10n.dart';
import '../support/reach.dart';
import '../support/service_key.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r, [String what = '']) {
  if (r case Err(:final failure)) fail('$what refused: ${failure.message}');
  return (r as Ok<T>).value;
}

String _nonce() => DateTime.now().microsecondsSinceEpoch.toString();

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

class _App {
  _App(this.client, {String? id}) {
    final me = id ?? client.auth.currentUser!.id;
    container = ProviderContainer.test(
      overrides: [
        sessionControllerProvider.overrideWith(
          () => _SignedIn(Member(userId: me, displayName: me)),
        ),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
        groupSettingsRepositoryProvider.overrideWithValue(
          SupabaseGroupSettingsRepository(client),
        ),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(client),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(client),
        ),
      ],
    );
    container.listen(conversationListProvider, (_, _) {});
  }

  final SupabaseClient client;
  late final ProviderContainer container;

  Future<void> ready() async {
    await container.read(sessionControllerProvider.future);
    await container.read(conversationListProvider.future);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient pace, quill, rush, service;

  String idOf(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    pace = await _signedIn('pace@integration.test');
    quill = await _signedIn('quill@integration.test');
    rush = await _signedIn('rush@integration.test');
    service = SupabaseClient(_url, serviceKey());
    // pace reaches quill and rush (stored, so a quick rerun may hit RLMT1).
    try {
      await findByTag(pace, [quill, rush]);
    } on PostgrestException catch (e) {
      if (e.code != 'RLMT1') rethrow;
    }
    // The add page lists pace's people: someone he shares a chat with.
    _ok(
      await SupabaseChatRepository(pace).startDirectConversation(idOf(rush)),
      'pace and rush chat',
    );
  });

  tearDownAll(() async {
    for (final c in [pace, quill, rush, service]) {
      await c.dispose();
    }
  });

  Future<void> runCase(
    WidgetTester t, {
    required bool groupSetting,
    required bool flipTo,
  }) async {
    final g = (await t.runAsync(() async {
      return _ok(
        await SupabaseChatRepository(pace).startGroupConversation(
          title: 'ah ${_nonce()}',
          memberIds: [idOf(quill)],
        ),
        'start group',
      );
    }))!;

    if (!groupSetting) {
      await t.runAsync(() async {
        await service
            .from('conversations')
            .update({'new_members_see_history': false})
            .eq('id', g);
      });
    }

    final old = (await t.runAsync(() async {
      return _ok(
        await SupabaseChatRepository(pace).send(
          id: randomMessageId(),
          conversationId: g,
          body: 'old ${_nonce()}',
        ),
        'old message',
      );
    }))!;

    final app = _App(pace);
    await t.runAsync(() async {
      await app.ready();
    });

    await t.pumpWidget(
      UncontrolledProviderScope(
        container: app.container,
        child: localizedApp(
          home: Builder(
            builder: (c) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute<void>(
                  builder: (_) => AddMembersPage(
                    g,
                    current: {idOf(pace), idOf(quill)},
                    groupTitle: 'ah',
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await t.tap(find.byKey(const ValueKey('open')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    Future<void> until(bool Function() done, String what) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) {
          fail(
            'timed out: $what; keys shown: ${find.byWidgetPredicate((w) => w.key is ValueKey<String>, skipOffstage: false).evaluate().map((e) => (e.widget.key! as ValueKey<String>).value).toList()}',
          );
        }
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
      }
    }

    await until(
      () =>
          find
              .byKey(ValueKey('add-member-${idOf(rush)}'), skipOffstage: false)
              .evaluate()
              .isNotEmpty &&
          find
              .byKey(const ValueKey('add-members-history'), skipOffstage: false)
              .evaluate()
              .isNotEmpty,
      'rush row and switch',
    );

    final switchFinder = find.byKey(
      const ValueKey('add-members-history'),
      skipOffstage: false,
    );
    expect(t.widget<SisSwitchTile>(switchFinder).value, groupSetting);

    if (flipTo != groupSetting) {
      await t.ensureVisible(switchFinder);
      await t.pump();
      await t.tap(switchFinder);
      await t.pump();
      expect(t.widget<SisSwitchTile>(switchFinder).value, flipTo);
    }

    final rushRow = find.byKey(
      ValueKey('add-member-${idOf(rush)}'),
      skipOffstage: false,
    );
    await t.ensureVisible(rushRow);
    await t.pump();
    await t.tap(rushRow);
    await t.pump();

    final confirm = find.byKey(
      const ValueKey('add-members-confirm'),
      skipOffstage: false,
    );
    await t.ensureVisible(confirm);
    await t.pump();
    await t.tap(confirm);
    await t.pump();

    await until(
      () =>
          find.text('Added to the group').evaluate().isNotEmpty ||
          find.byKey(const ValueKey('add-members-page')).evaluate().isEmpty,
      'confirmation',
    );

    await t.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!_ok(await SupabaseChatRepository(rush).conversations())
          .any((c) => c.id == g)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out: rush sees the group');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final seen = _ok(await SupabaseChatRepository(rush).messages(g))
          .map((m) => m.id);
      if (flipTo) {
        expect(seen, contains(old.id), reason: 'old message visible');
      } else {
        expect(seen, isNot(contains(old.id)), reason: 'old message hidden');
      }
    });

    await t.pumpWidget(const SizedBox());
    // Disposed here, not in a tear-down: its channels close on the fake
    // clock, which the pump below runs out.
    app.container.dispose();
    // Channel replies arrive on the real clock and schedule their
    // disconnect timers on the fake one: let them land, then run them out.
    for (var i = 0; i < 2; i++) {
      await t.runAsync(() async {
        await pace.removeAllChannels();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pump(const Duration(seconds: 61));
    }
  }

  testWidgets(
    'admin turns the switch off: the added member cannot read older messages',
    (t) async {
      await runCase(t, groupSetting: true, flipTo: false);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'admin turns the switch on: the added member reads older messages',
    (t) async {
      await runCase(t, groupSetting: false, flipTo: true);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets('switch untouched: the group setting (off) decides', (t) async {
    await runCase(t, groupSetting: false, flipTo: false);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
