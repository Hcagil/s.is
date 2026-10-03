@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// Messages strictly per chat (0.30.7), against the real stack: the REAL
/// MessagesController on the REAL SupabaseChatRepository, real PostgREST and
/// real Realtime, mounted as production mounts it (only the repository is
/// overridden).
///
/// The defect: one messagesProvider carried the chat just left into the next
/// one -- open What's new, then another chat at once, and the second showed
/// What's new's rows until its own read landed; a Realtime row for the chat
/// just left could land in the new one. Here every value the provider takes
/// after a switch is recorded, and none may belong to another chat.
///
/// Requires a running local Supabase and the warmup probe. mira/nico are this
/// suite's own (supabase/seed.sql).
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

Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 25),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (matches(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out after $timeout: $reason');
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

void main() {
  SupabaseClient? miraClient;
  SupabaseClient? nicoClient;
  SupabaseClient? service;
  late SupabaseChatRepository mira;
  late SupabaseChatRepository nico;
  late String sis;
  late String direct;
  late String group;
  final notes = <int>[];

  setUpAll(() async {
    service = _client(serviceKey());
    nicoClient = await _signedIn('nico@integration.test');
    miraClient = await _signedIn('mira@integration.test');
    mira = SupabaseChatRepository(miraClient!);
    nico = SupabaseChatRepository(nicoClient!);
    await findByTag(miraClient!, [nicoClient!]);

    // What's new: a note newer than any mira was served reaches her SIS chat.
    final base =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1700000000) * 10;
    await miraClient!.rpc(
      'deliver_release_notes',
      params: {'installed_build': base},
    );
    await service!.from('release_notes').insert({
      'build': base + 1,
      'note': _stamp('note'),
    });
    notes.add(base + 1);
    await miraClient!.rpc(
      'deliver_release_notes',
      params: {'installed_build': base + 1},
    );
    final sys = await miraClient!
        .from('conversations')
        .select('id')
        .eq('system', true);
    sis = sys.single['id'] as String;

    direct = (await mira.startDirectConversation(
      nicoClient!.auth.currentUser!.id,
    ) as Ok<String>).value;
    group = (await mira.startGroupConversation(
      title: _stamp('per-chat'),
      memberIds: [nicoClient!.auth.currentUser!.id],
    ) as Ok<String>).value;
    for (final (chat, body) in [
      (direct, 'direct seed'),
      (group, 'group seed'),
    ]) {
      expect(
        await nico.send(
          id: randomMessageId(),
          conversationId: chat,
          body: body,
        ),
        isA<Ok<Message>>(),
      );
    }
  });

  tearDownAll(() async {
    if (notes.isNotEmpty) {
      await service?.from('release_notes').delete().inFilter('build', notes);
    }
    await miraClient?.dispose();
    await nicoClient?.dispose();
    await service?.dispose();
  });

  ProviderContainer container() => ProviderContainer.test(
    overrides: [chatRepositoryProvider.overrideWithValue(mira)],
  );

  /// Every value messagesProvider takes from now on.
  List<List<Message>?> record(ProviderContainer c) {
    final seen = <List<Message>?>[];
    c.listen(
      messagesProvider,
      (_, next) => seen.add(next.value),
      fireImmediately: true,
    );
    return seen;
  }

  void onlyFrom(List<List<Message>?> seen, String chat, String what) {
    for (final value in seen) {
      for (final m in value ?? const <Message>[]) {
        expect(
          m.conversationId,
          chat,
          reason: '$what: "${m.body}" of ${m.conversationId} shown in $chat',
        );
      }
    }
  }

  List<Message> shown(ProviderContainer c) =>
      c.read(messagesProvider).value ?? const [];

  test("What's new, then a 1:1 at once: never What's new's rows in the 1:1, "
      'then its own', () async {
    final c = container();
    final seen = record(c);
    c.read(openConversationProvider.notifier).open(sis);
    final whatsNew = await c.read(messagesProvider.future);
    expect(whatsNew, isNotEmpty, reason: "What's new must hold the note");
    expect(whatsNew.every((m) => m.conversationId == sis), isTrue);

    final mark = seen.length;
    c.read(openConversationProvider.notifier).open(direct);
    await eventually(
      () => shown(c),
      (l) => l.any((m) => m.body == 'direct seed'),
      reason: 'the 1:1 never loaded',
    );
    onlyFrom(seen.sublist(mark), direct, "after What's new");
  });

  test('A -> null -> B in one go: only B rows', () async {
    final c = container();
    final seen = record(c);
    c.read(openConversationProvider.notifier).open(group);
    await c.read(messagesProvider.future);
    final mark = seen.length;
    c.read(openConversationProvider.notifier).close();
    c.read(openConversationProvider.notifier).open(direct);
    await eventually(
      () => shown(c),
      (l) => l.any((m) => m.body == 'direct seed'),
      reason: 'the 1:1 never loaded',
    );
    onlyFrom(seen.sublist(mark), direct, 'after the group and null');
  });

  test('group -> 1:1, then the other member writes into the group: dropped; '
      'into the 1:1: shown live', () async {
    final c = container();
    final seen = record(c);
    c.read(openConversationProvider.notifier).open(group);
    await c.read(messagesProvider.future);

    final mark = seen.length;
    c.read(openConversationProvider.notifier).open(direct);
    final late = _stamp('late for the group');
    expect(
      await nico.send(id: randomMessageId(), conversationId: group, body: late),
      isA<Ok<Message>>(),
    );
    await c.read(messagesProvider.future);

    // A row in the open chat, sent after the group's: once it is shown, the
    // group's (if it were coming) has had every chance to arrive.
    final probe = _stamp('probe');
    expect(
      await nico.send(
        id: randomMessageId(),
        conversationId: direct,
        body: probe,
      ),
      isA<Ok<Message>>(),
    );
    await eventually(
      () => shown(c),
      (l) => l.any((m) => m.body == probe),
      reason: 'the 1:1 subscription never delivered',
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(shown(c).map((m) => m.body), isNot(contains(late)));
    onlyFrom(seen.sublist(mark), direct, 'after leaving the group');
  });
}
