@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';

/// Scrolling back down to the newest message (0.30.16) against the real
/// local stack, MessagesController over SupabaseChatRepository and real
/// Realtime:
/// - open the newest page, loadOlder twice, then a row inserted by the other
///   member while scrolled up arrives;
/// - a jump to an old message, then loadNewer until live, reaches the
///   newest message with no gap and no duplicate;
/// - verifyNewest picks up a row inserted while the reader's Realtime was
///   gone.
///
/// The owner's defect (0.30.14): after scrolling up, scrolling down got stuck
/// until the chat was reopened. A fake decides itself what "the page after"
/// is; here the real messagesAround window does.
///
/// Requires `docker compose run --rm supabase start`. sda and sdb are this
/// suite's own seeded pair (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

const _total = 160;

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
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => fail('expected Ok, got ${failure.message}'),
};

Future<void> _eventually(
  bool Function() done, {
  required String reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Every Realtime channel [client] holds has joined.
Future<void> _joined(SupabaseClient client) => _eventually(() {
  final cs = client.getChannels();
  return cs.isNotEmpty && cs.every((c) => c.canPush);
}, reason: 'the subscription never joined');

void main() {
  late SupabaseClient sdb;
  late SupabaseClient sda;
  late String chat;

  /// Message ids by index, oldest first.
  final ids = <String>[];

  Future<String> write(String body) async {
    final id = randomMessageId();
    await sdb.from('messages').insert({
      'id': id,
      'conversation_id': chat,
      'sender_id': sdb.auth.currentUser!.id,
      'body': body,
    });
    return id;
  }

  setUpAll(() async {
    sdb = await _signedIn('sdb@integration.test');
    sda = await _signedIn('sda@integration.test');
    await findByTag(sdb, [sda]);
    // A group: always a fresh conversation, so a rerun starts clean.
    chat = _ok(
      await SupabaseChatRepository(sdb).startGroupConversation(
        title: 'scroll ${DateTime.now().microsecondsSinceEpoch}',
        memberIds: [sda.auth.currentUser!.id],
      ),
    );
    // One insert per row: created_at is the transaction's now().
    for (var i = 0; i < _total; i++) {
      ids.add(await write('row $i'));
    }
  });

  tearDownAll(() async {
    await sdb.dispose();
    await sda.dispose();
  });

  ProviderContainer open(SupabaseClient reader) {
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(reader),
        ),
      ],
    );
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(chat);
    return c;
  }

  List<String> shownIn(ProviderContainer c) =>
      (c.read(messagesProvider).value ?? const <Message>[])
          .map((m) => m.id)
          .toList();

  Future<String> newestOnServer() async =>
      _ok(await SupabaseChatRepository(sda).messages(chat)).last.id;

  test('loadOlder twice, then a row written by the other member while '
      'scrolled up arrives at the bottom', () async {
    final c = open(sda);
    addTearDown(c.dispose);
    await c.read(messagesProvider.future);
    expect(shownIn(c), ids.sublist(_total - messagePageSize));
    final controller = c.read(messagesProvider.notifier);
    await _joined(sda);
    await controller.loadOlder();
    await controller.loadOlder();
    expect(shownIn(c).length, messagePageSize * 3, reason: 'two older pages');
    expect(shownIn(c).first, ids[_total - 3 * messagePageSize]);

    final late = await write('while scrolled up');
    ids.add(late);
    await _eventually(
      () => shownIn(c).isNotEmpty && shownIn(c).last == late,
      reason:
          'the live row never reached the bottom: '
          'contains=${shownIn(c).contains(late)} last=${shownIn(c).last} '
          'channels=${sda.getChannels().map((x) => x.canPush)}',
    );
    expect(shownIn(c).toSet(), hasLength(shownIn(c).length));
  });

  test('a jump to an old message, then loadNewer until live, reaches the '
      'newest message with no gap', () async {
    final c = open(sda);
    addTearDown(c.dispose);
    final rows = await c.read(messagesProvider.future);
    final controller = c.read(messagesProvider.notifier);
    final anchor = _ok(
      await SupabaseChatRepository(sda).messagesAround(chat, rows.first),
    ).first;
    // Old enough that the newest page is far away (>= two windows).
    final oldest = _ok(
      await SupabaseChatRepository(sda).messagesAround(chat, anchor),
    ).first;
    expect(await controller.jumpToAround(oldest), isA<Ok<void>>());
    expect(controller.isJumped, isTrue);
    expect(shownIn(c), isNot(contains(ids.last)), reason: 'fixture: far');

    var pages = 0;
    while (controller.isJumped) {
      if (++pages > 10) fail('never reached live: ${shownIn(c).length}');
      await controller.loadNewer();
    }
    final newest = await newestOnServer();
    await _eventually(
      () => shownIn(c).isNotEmpty && shownIn(c).last == newest,
      reason: 'the live end was not the newest message',
    );
    final shown = shownIn(c);
    final from = ids.indexOf(shown.first);
    expect(from, greaterThanOrEqualTo(0));
    expect(shown, ids.sublist(from), reason: 'no gap, no duplicate, in order');
  });

  test('verifyNewest picks up a row written while Realtime was gone', () async {
    // Its own reader: dropping Realtime must not touch the other tests.
    final reader = await _signedIn('sda@integration.test');
    addTearDown(reader.dispose);
    final c = open(reader);
    addTearDown(c.dispose);
    await c.read(messagesProvider.future);
    await _joined(reader);
    // The socket is gone, as on a phone the OS put to sleep.
    await reader.removeAllChannels();
    final missed = await write('while the socket was gone');
    ids.add(missed);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(shownIn(c), isNot(contains(missed)), reason: 'fixture: missed');

    c.read(messagesProvider.notifier).verifyNewest();
    await _eventually(
      () => shownIn(c).isNotEmpty && shownIn(c).last == missed,
      reason: 'verifyNewest did not read the missed row in',
    );
  });
}
