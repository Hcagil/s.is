@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/links.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';

/// The profile pages' three reads through the real stack --
/// [SupabaseChatRepository.conversationMembers], `sharedMedia` and
/// `sharedLinks` against the real tables and row-level security -- and the
/// seam the pages sit on: the real controllers and Realtime underneath the
/// group chat -> group page -> member -> Message -> back, back, back path.
///
/// Requires a running local Supabase and the warmup probe. Accounts fern,
/// gus, hugo and ines are this suite's own (supabase/seed.sql). Ines is
/// allowlisted and active but in none of the conversations here, so only
/// membership can keep their rows from her.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
const _deadUrl = 'http://127.0.0.1:1';

SupabaseClient _client(String url) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_url);
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

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

/// Display names chosen so that name order is neither email order nor
/// (in general) id order: Ana Gus, Mia Hugo, Zoe Fern.
const _names = {'fern': 'Zoe Fern', 'gus': 'Ana Gus', 'hugo': 'Mia Hugo'};

String _uid(SupabaseClient c) => c.auth.currentUser!.id;

/// A real 1x1 PNG: messages_send now requires the sender to own a real
/// storage object at attachment_path (20260924140000_delete_for_everyone.sql),
/// so every photo fixture below needs a real upload first, not just a path.
final _photoBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Uploads a real object at [path], owned by [c]'s account, so a message
/// naming it as its attachment_path passes ownership -- and, for the folder
/// check in the same policy, so [path] must already start with the
/// conversation id it is inserted into.
Future<void> _uploadPhoto(SupabaseClient c, String path) => c.storage
    .from('attachments')
    .uploadBinary(
      path,
      _photoBytes,
      fileOptions: const FileOptions(contentType: 'image/png'),
    );

/// One message written straight into the table, the way the app's own
/// inserts land (the server sets id and created_at) -- except the upload,
/// which the app does through [ChatRepository.sendImage] and this suite
/// does directly, since it is exercising the read side, not the send.
Future<String> _insert(
  SupabaseClient c,
  String conversation, {
  String body = '',
  String? photo,
}) async {
  if (photo != null) await _uploadPhoto(c, photo);
  final row = await c
      .from('messages')
      .insert({
        'conversation_id': conversation,
        'sender_id': _uid(c),
        'body': body,
        'attachment_path': ?photo,
      })
      .select('id')
      .single();
  return row['id'] as String;
}

/// Many rows in ONE statement: they share a created_at. Every photo path is
/// uploaded first (concurrently, in bounded batches so a few hundred of them
/// do not open a few hundred sockets at once), for the same reason as above.
Future<void> _bulk(
  SupabaseClient c,
  String conversation,
  int n, {
  String Function(int)? body,
  String Function(int)? photo,
}) async {
  if (photo != null) {
    const batchSize = 25;
    for (var start = 0; start < n; start += batchSize) {
      final end = (start + batchSize < n) ? start + batchSize : n;
      await Future.wait([
        for (var i = start; i < end; i++) _uploadPhoto(c, photo(i)),
      ]);
    }
  }
  await c.from('messages').insert([
    for (var i = 0; i < n; i++)
      {
        'conversation_id': conversation,
        'sender_id': _uid(c),
        'body': body?.call(i) ?? '',
        'attachment_path': ?photo?.call(i),
      },
  ]);
}

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

void _newestFirst(List<Message> list) {
  for (var i = 1; i < list.length; i++) {
    expect(
      list[i - 1].createdAt.isBefore(list[i].createdAt),
      isFalse,
      reason: 'not newest first at $i',
    );
  }
}

/// Google sign-in cannot run locally, so auth is the one boundary faked: the
/// session is the account's real one, activated against the real database.
class _AccountAuth implements AuthRepository {
  _AccountAuth(this.client, this.name);
  final SupabaseClient client;
  final String name;

  @override
  bool get hasSession => client.auth.currentSession != null;
  @override
  Stream<bool> get signedInChanges => const Stream.empty();
  @override
  Future<Result<void>> signInWithGoogle() async => const Ok(null);
  @override
  Future<Result<bool>> activateSession() async =>
      Ok(await client.rpc('activate_session') as bool);
  @override
  Future<Result<Member>> currentMember() async =>
      Ok(Member(userId: client.auth.currentUser!.id, displayName: name));
  @override
  Future<void> signOut() async {}
}

void main() {
  // testWidgets below installs a binding that answers every HTTP request with
  // 400; this suite talks to a real server.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? fernClient, gusClient, hugoClient, inesClient, deadClient;
  late SupabaseChatRepository fern, gus, hugo, ines, dead;
  final tags = <String, String>{};

  setUpAll(() async {
    fernClient = await _signedIn('fern@integration.test');
    gusClient = await _signedIn('gus@integration.test');
    hugoClient = await _signedIn('hugo@integration.test');
    inesClient = await _signedIn('ines@integration.test');
    deadClient = _client(_deadUrl);
    fern = SupabaseChatRepository(fernClient!);
    gus = SupabaseChatRepository(gusClient!);
    hugo = SupabaseChatRepository(hugoClient!);
    ines = SupabaseChatRepository(inesClient!);
    dead = SupabaseChatRepository(deadClient!);
    for (final (who, c) in [
      ('fern', fernClient!),
      ('gus', gusClient!),
      ('hugo', hugoClient!),
    ]) {
      await c
          .from('profiles')
          .update({'display_name': _names[who], 'onboarding_done': true})
          .eq('user_id', _uid(c));
      final row = await c
          .from('profiles')
          .select('tag')
          .eq('user_id', _uid(c))
          .single();
      tags[_uid(c)] = row['tag'] as String;
    }
  });

  tearDownAll(() async {
    await fernClient?.dispose();
    await gusClient?.dispose();
    await hugoClient?.dispose();
    await inesClient?.dispose();
    await deadClient?.dispose();
  });

  Future<String> freshGroup(String what) async => _ok(
    await fern.startGroupConversation(
      title: _stamp(what),
      memberIds: [_uid(gusClient!), _uid(hugoClient!)],
    ),
    'creating the group',
  );

  group('conversationMembers', () {
    test('a group: all three, the caller included, by display name, with '
        'names and tags', () async {
      final g = await freshGroup('members');
      final got = _ok(await fern.conversationMembers(g), 'members');
      expect(got.map((m) => m.displayName), [
        'Ana Gus',
        'Mia Hugo',
        'Zoe Fern',
      ]);
      expect(got.map((m) => m.userId), [
        _uid(gusClient!),
        _uid(hugoClient!),
        _uid(fernClient!),
      ]);
      for (final m in got) {
        expect(m.tag, tags[m.userId], reason: 'tag of ${m.displayName}');
        expect(m.email, isNull, reason: 'nobody\'s email is read here');
      }
      // Every member sees the same list.
      final fromHugo = _ok(await hugo.conversationMembers(g), 'hugo');
      expect(fromHugo.map((m) => m.userId), got.map((m) => m.userId));
    });

    test('a 1:1: both people', () async {
      final c = _ok(
        await fern.startDirectConversation(_uid(gusClient!)),
        'start',
      );
      final got = _ok(await gus.conversationMembers(c), 'members');
      expect(got.map((m) => m.displayName), ['Ana Gus', 'Zoe Fern']);
    });

    test('a non-member learns nothing about who is in it', () async {
      final g = await freshGroup('outsider');
      final r = await ines.conversationMembers(g);
      if (r case Ok(:final value)) {
        expect(value, isEmpty, reason: 'RLS leaked members to an outsider');
      }
    });

    test('an unreachable server is an Err, not a throw', () async {
      final g = await freshGroup('dead members');
      expect(await dead.conversationMembers(g), isA<Err<List<Member>>>());
    });
  });

  group('sharedMedia', () {
    test('only messages with a photo, newest first', () async {
      final g = await freshGroup('media');
      final a = await _insert(fernClient!, g, photo: '$g/a.png');
      await _insert(gusClient!, g, body: 'no photo');
      final b = await _insert(gusClient!, g, photo: '$g/b.png', body: 'cap');
      await _insert(hugoClient!, g, body: 'https://still.not.a.photo');
      final c = await _insert(hugoClient!, g, photo: '$g/c.png');
      final got = _ok(await fern.sharedMedia(g), 'media');
      expect(got.map((m) => m.id), [c, b, a]);
      expect(got.map((m) => m.attachmentPath), [
        '$g/c.png',
        '$g/b.png',
        '$g/a.png',
      ]);
      expect(got.every((m) => m.conversationId == g), isTrue);
      _newestFirst(got);
    });

    test('capped at 500 photos, the newest, even under newer text', () async {
      final g = await freshGroup('media cap');
      await _bulk(fernClient!, g, 505, photo: (i) => '$g/old$i.png');
      final newest = await _insert(fernClient!, g, photo: '$g/newest.png');
      // Newer than every photo: a read that caps before it filters sees none.
      await _bulk(fernClient!, g, 600, body: (i) => 'text $i');
      final got = _ok(await fern.sharedMedia(g), 'media');
      expect(got, hasLength(500));
      expect(got.first.id, newest);
      expect(got.every((m) => m.hasAttachment), isTrue);
      _newestFirst(got);
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a non-member sees no photos', () async {
      final g = await freshGroup('media outsider');
      await _insert(fernClient!, g, photo: '$g/secret.png');
      final r = await ines.sharedMedia(g);
      if (r case Ok(:final value)) expect(value, isEmpty);
    });

    test('an unreachable server is an Err', () async {
      expect(
        await dead.sharedMedia('00000000-0000-0000-0000-000000000000'),
        isA<Err<List<Message>>>(),
      );
    });
  });

  group('sharedLinks', () {
    /// Every body here, and whether it contains http://, https:// or www.
    /// ignoring case -- the contract's filter.
    const corpus = [
      'plain words',
      'https://example.com/a',
      'HTTP://EXAMPLE.COM',
      'WwW.Example.org',
      'see www.x.io, ok',
      'HtTpS://mixed.case/path?q=1',
      'mailto:a@www.example.com',
      'http:// alone',
      'https://',
      'x https://<y>',
      'www.',
      'ftp://files.example',
      'wwwexample.com',
      'http:/example.com',
      'https ://x.com',
      'a%b_c www_x 100%',
      'quote "https://q.example" done',
      'comma,https://c.example,x',
      'star*https://s.example*',
      '(https://p.example)',
    ];
    final contract = RegExp(r'http://|https://|www\.', caseSensitive: false);

    test(
      'newest first, and exactly the rows that contain an address',
      () async {
        final g = await freshGroup('links');
        final ids = <String, String>{};
        for (final (i, body) in corpus.indexed) {
          final who = [fernClient!, gusClient!, hugoClient!][i % 3];
          ids[await _insert(who, g, body: body)] = body;
        }
        final captioned = await _insert(
          fernClient!,
          g,
          photo: '$g/cap.png',
          body: 'caption www.cap.example',
        );
        await _insert(fernClient!, g, photo: '$g/bare.png');
        ids[captioned] = 'caption www.cap.example';

        final got = _ok(await fern.sharedLinks(g), 'links');
        _newestFirst(got);
        final returned = {for (final m in got) m.id: m.body};

        final byContract = {
          for (final e in ids.entries)
            if (contract.hasMatch(e.value)) e.key,
        };
        expect(
          returned.keys.toSet(),
          byContract,
          reason: 'the filter is not "contains http://, https:// or www."',
        );

        // Newest first by insertion, too (each insert is its own statement).
        final order = [
          for (final id in ids.keys.toList().reversed)
            if (byContract.contains(id)) id,
        ];
        expect(got.map((m) => m.id), order);

        // Against what the app will actually show: the rows linkSegments finds
        // a link in. A miss is a link the Links tab can never show.
        final withLinks = {
          for (final e in ids.entries)
            if (extractLinks(e.value).isNotEmpty) e.key,
        };
        final misses = withLinks.difference(returned.keys.toSet());
        expect(
          misses.map((id) => ids[id]),
          isEmpty,
          reason: 'rows with a real link the filter dropped',
        );
        final extras = returned.keys.toSet().difference(withLinks);
        // Not a failure (the contract filter is textual), but reported: each
        // extra row costs a slot under the 500 cap and yields no link.
        // ignore: avoid_print
        print(
          'sharedLinks rows with no link linkSegments recognises: '
          '${[for (final id in extras) ids[id]]}',
        );
      },
    );

    test(
      'capped at 500 link messages, the newest, even under newer text',
      () async {
        final g = await freshGroup('links cap');
        await _bulk(gusClient!, g, 505, body: (i) => 'https://old$i.example');
        final newest = await _insert(gusClient!, g, body: 'www.newest.example');
        await _bulk(gusClient!, g, 600, body: (i) => 'no address $i');
        final got = _ok(await fern.sharedLinks(g), 'links');
        expect(got, hasLength(500));
        expect(got.first.id, newest);
        expect(got.every((m) => contract.hasMatch(m.body)), isTrue);
        _newestFirst(got);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test('a non-member sees no links', () async {
      final g = await freshGroup('links outsider');
      await _insert(fernClient!, g, body: 'https://secret.example');
      final r = await ines.sharedLinks(g);
      if (r case Ok(:final value)) expect(value, isEmpty);
    });

    test('an unreachable server is an Err', () async {
      expect(
        await dead.sharedLinks('00000000-0000-0000-0000-000000000000'),
        isA<Err<List<Message>>>(),
      );
    });
  });

  group('providers over the real repository', () {
    test('conversationMembersProvider: data, and AsyncError with the Failure '
        'from a dead host', () async {
      final g = await freshGroup('provider');
      final live = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(fern)],
      );
      final sub = live.listen(conversationMembersProvider(g), (_, _) {});
      final got = await live.read(conversationMembersProvider(g).future);
      expect(got, hasLength(3));
      sub.close();

      final down = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(dead)],
      );
      final s2 = down.listen(sharedLinksProvider(g), (_, _) {});
      await expectLater(
        down.read(sharedLinksProvider(g).future),
        throwsA(isA<Failure>()),
      );
      expect(s2.read().error, isA<Failure>());
      s2.close();
    });
  });

  group('the pages on the real stack', () {
    Widget app() => ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'c',
          ),
        ),
        authRepositoryProvider.overrideWithValue(
          _AccountAuth(fernClient!, 'Zoe Fern'),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(fern),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(fernClient!),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(fernClient!),
        ),
        attachmentSourceProvider.overrideWithValue(PickerFake.cancels()),
      ],
      child: const SisApp(),
    );

    Future<void> until(WidgetTester t, bool Function() ok, String what) async {
      for (var i = 0; i < 150; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        // Advance the fake clock too, so route transitions finish.
        await t.pump(const Duration(milliseconds: 100));
        if (ok()) return;
      }
      fail('never happened: $what');
    }

    Finder byKey(String k) => find.byKey(ValueKey(k));
    bool shows(Finder f) => f.evaluate().isNotEmpty;

    /// [text] inside an open chat -- not the list's preview of it.
    Finder inChat(String text) => find.descendant(
      of: find.byType(MessageScreen),
      matching: find.text(text),
    );

    testWidgets('group chat -> page -> member -> Message -> back x3: the '
        'group chat is open again and its Realtime still delivers', (t) async {
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);

      final g = (await t.runAsync(() => freshGroup('seam')))!;
      final direct = (await t.runAsync(
        () async =>
            _ok(await fern.startDirectConversation(_uid(gusClient!)), 'start'),
      ))!;
      final inGroup = _stamp('group before');
      final inDirect = _stamp('direct before');
      await t.runAsync(() async {
        await gus.send(conversationId: g, body: inGroup);
        await gus.send(conversationId: direct, body: inDirect);
      });

      await t.pumpWidget(app());
      await until(t, () => shows(byKey('conversation-$g')), 'the list');
      final container = ProviderScope.containerOf(
        t.element(find.byType(SisApp)),
      );

      await t.tap(byKey('conversation-$g'));
      await until(t, () => shows(inChat(inGroup)), 'the group chat');
      expect(container.read(openConversationProvider), g);

      await t.tap(byKey('conversation-title'));
      await until(t, () => shows(find.byType(GroupScreen)), 'the group page');
      final gusRow = byKey('group-member-${_uid(gusClient!)}');
      await until(t, () => shows(gusRow), 'the member list');
      await t.tap(gusRow);
      await until(t, () => shows(byKey('person-message')), 'Gus\'s page');
      await t.tap(byKey('person-message'));
      await until(t, () => shows(inChat(inDirect)), 'the 1:1 chat');
      expect(container.read(openConversationProvider), direct);

      for (final (page, name) in [
        (find.byType(PersonScreen), 'person page'),
        (find.byType(GroupScreen), 'group page'),
        (inChat(inGroup), 'group chat'),
      ]) {
        await t.pump(const Duration(seconds: 1)); // the last transition
        await t.pageBack();
        await t.pump(const Duration(seconds: 1));
        await until(t, () => shows(page), 'back to the $name');
      }
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(container.read(openConversationProvider), g);

      // Realtime: a message sent now must reach the group chat on screen.
      final live = _stamp('group after');
      await until(
        t,
        () => container.read(messagesProvider).hasValue,
        'the group chat reloaded',
      );
      await t.runAsync(() => hugo.send(conversationId: g, body: live));
      await until(t, () => shows(inChat(live)), 'the live group message');

      await t.pump(const Duration(seconds: 1));
      await t.pageBack();
      await until(
        t,
        () => container.read(openConversationProvider) == null,
        'leaving to the list clears the open conversation',
      );

      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => fernClient!.removeAllChannels());
      await t.runAsync(() => fernClient!.realtime.disconnect());
      await t.pump(const Duration(seconds: 61));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
