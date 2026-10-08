@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/video_fakes.dart';

/// Opening a chat with the join and the read in parallel (0.30.12), against
/// the real stack: the REAL MessagesController on the REAL
/// SupabaseChatRepository, real PostgREST, real Realtime, two members.
///
/// The opener's HTTP goes through [_Wire], which can stop the history read
/// at two moments -- before it reaches the server, and after the server
/// answered but before the answer is handed back -- while the other member
/// writes. Realtime is not touched. Each case asserts what the member sees:
/// every message once, nothing lost, an edit and a delete reflected.
///
/// Accounts kip/lyle are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// Passes everything through; the first history read of [chat] can be held
/// [before] it is sent and [after] its answer arrived.
class _Wire extends http.BaseClient {
  _Wire(this.chat);
  final String chat;
  final _inner = http.Client();
  Future<void> Function()? before;
  Future<void> Function()? after;
  final reads = <String>[];

  bool _isRead(http.BaseRequest r) =>
      r.method == 'GET' &&
      r.url.pathSegments.isNotEmpty &&
      r.url.pathSegments.last == 'messages' &&
      r.url.query.contains(chat);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final read = _isRead(request);
    if (read) reads.add(request.url.toString());
    if (read && before != null) {
      final hook = before!;
      before = null;
      await hook();
    }
    final res = await _inner.send(request);
    if (!(read && after != null)) return res;
    final hook = after!;
    after = null;
    final body = await res.stream.toBytes();
    await hook();
    return http.StreamedResponse(
      Stream.value(body),
      res.statusCode,
      contentLength: body.length,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

Future<SupabaseClient> _signedIn(String email, [http.Client? wire]) async {
  final client = SupabaseClient(
    _url,
    _key,
    httpClient: wire,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

Future<void> eventually(
  bool Function() ok, {
  Duration timeout = const Duration(seconds: 20),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: '$r');
  return (r as Ok<T>).value;
}

void main() {
  late SupabaseClient lyleClient;
  late SupabaseChatRepository lyle;
  late String chat;
  late String kipId;

  setUpAll(() async {
    lyleClient = await _signedIn('lyle@integration.test');
    final kip = await _signedIn('kip@integration.test');
    kipId = kip.auth.currentUser!.id;
    lyle = SupabaseChatRepository(lyleClient);
    await findByTag(lyleClient, [kip]);
    chat = _ok(await lyle.startDirectConversation(kipId));
    await kip.dispose();
  });

  tearDownAll(() async {
    await lyleClient.dispose();
  });

  Future<Message> lyleSays(String body) async => _ok(
    await lyle.send(id: randomMessageId(), conversationId: chat, body: body),
  );

  /// Kip opens the chat as production mounts it (only the repository is
  /// overridden), on a fresh client so the Realtime join starts from cold.
  Future<({ProviderContainer c, SupabaseClient client, _Wire wire})> kipOpens({
    Future<void> Function(SupabaseClient client)? before,
    Future<void> Function(SupabaseClient client)? after,
  }) async {
    final wire = _Wire(chat);
    final client = await _signedIn('kip@integration.test', wire);
    if (before != null) wire.before = () => before(client);
    if (after != null) wire.after = () => after(client);
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
      ],
    );
    addTearDown(() async {
      c.dispose();
      await client.dispose();
    });
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(chat);
    return (c: c, client: client, wire: wire);
  }

  bool joined(SupabaseClient client) {
    final cs = client.getChannels();
    return cs.isNotEmpty && cs.every((ch) => ch.canPush);
  }

  /// The join is confirmed (with a margin for the server to route changes).
  Future<void> waitJoined(SupabaseClient client) async {
    await eventually(() => joined(client), reason: 'never joined');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  List<Message> shown(ProviderContainer c) =>
      c.read(messagesProvider).value ?? const [];

  /// Every message once, in createdAt order, and [bodies] all among them.
  void expectOnceEach(ProviderContainer c, List<String> bodies) {
    final rows = shown(c);
    final ids = [for (final m in rows) m.id];
    expect(ids.toSet().length, ids.length, reason: 'a duplicate id: $ids');
    for (var i = 1; i < rows.length; i++) {
      expect(
        rows[i - 1].createdAt.isAfter(rows[i].createdAt),
        isFalse,
        reason: 'out of createdAt order at $i',
      );
    }
    for (final b in bodies) {
      expect(
        rows.where((m) => m.body == b).length,
        1,
        reason: '"$b" must show exactly once',
      );
    }
  }

  /// Lets the open, its verify re-read and any late event finish.
  Future<void> settle(ProviderContainer c) async {
    await c.read(messagesProvider.future);
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  test('(a) an insert after the join is confirmed, before the read is served, '
      'shows once', () async {
    final seed = _stamp('seed-a');
    await lyleSays(seed);
    final text = _stamp('a');
    final k = await kipOpens(
      before: (client) async {
        await waitJoined(client);
        await lyleSays(text);
      },
    );
    await settle(k.c);
    expect(k.wire.before, isNull, reason: 'the hook never ran');
    expectOnceEach(k.c, [seed, text]);
  });

  test('(b) an insert after the read was served, before its answer lands, '
      'shows once', () async {
    final text = _stamp('b');
    final k = await kipOpens(
      after: (client) async {
        await waitJoined(client);
        await lyleSays(text);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      },
    );
    await settle(k.c);
    expect(k.wire.after, isNull, reason: 'the hook never ran');
    expectOnceEach(k.c, [text]);
  });

  test('(c) an insert while the join is still pending, after the read was '
      'served, shows once', () async {
    var hit = false;
    for (var attempt = 0; attempt < 3 && !hit; attempt++) {
      final text = _stamp('c$attempt');
      final k = await kipOpens(
        after: (client) async {
          hit = !joined(client);
          await lyleSays(text);
        },
      );
      await settle(k.c);
      expect(k.wire.after, isNull, reason: 'the hook never ran');
      await eventually(
        () => shown(k.c).any((m) => m.body == text),
        reason: 'the message written in the window never showed',
      );
      expectOnceEach(k.c, [text]);
    }
    if (!hit) {
      // ignore: avoid_print
      print(
        'NOTE (c): the join was confirmed before the read was served in '
        'all 3 attempts; this run covered (b) again, not (c)',
      );
    }
  });

  test('(d) an edit and a delete of existing rows while the read is in '
      'flight are reflected; a stale read never reverts them', () async {
    final keep = await lyleSays(_stamp('to-edit'));
    final gone = await lyleSays(_stamp('to-delete'));
    final fixed = _stamp('fixed');
    final k = await kipOpens(
      after: (client) async {
        await waitJoined(client);
        _ok(await lyle.editMessage(keep, fixed));
        _ok(await lyle.deleteForEveryone(gone));
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      },
    );
    await settle(k.c);
    expect(k.wire.after, isNull, reason: 'the hook never ran');

    final rows = shown(k.c);
    final ids = [for (final m in rows) m.id];
    expect(ids.toSet().length, ids.length, reason: 'a duplicate id: $ids');
    final edited = rows.singleWhere((m) => m.id == keep.id);
    expect(edited.body, fixed, reason: 'the live edit was reverted');
    expect(edited.isEdited, isTrue);
    final deleted = rows.where((m) => m.id == gone.id);
    expect(
      deleted.every((m) => m.isDeleted),
      isTrue,
      reason: 'the live delete was undone: $deleted',
    );
  });

  test('(e) an edit and a delete made before the open are what the open '
      'shows', () async {
    final keep = await lyleSays(_stamp('pre-edit'));
    final gone = await lyleSays(_stamp('pre-delete'));
    final fixed = _stamp('pre-fixed');
    _ok(await lyle.editMessage(keep, fixed));
    _ok(await lyle.deleteForEveryone(gone));
    final k = await kipOpens();
    await settle(k.c);
    final rows = shown(k.c);
    expect(rows.singleWhere((m) => m.id == keep.id).body, fixed);
    expect(rows.where((m) => m.id == gone.id).every((m) => m.isDeleted), true);
  });
}
