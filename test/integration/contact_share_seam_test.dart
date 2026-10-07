@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_contact_share_repository.dart';
import 'package:sis/features/chat/data/supabase_poll_repository.dart';
import 'package:sis/features/chat/data/supabase_reaction_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';

/// The seam MessagesController.sendContact <-> SupabaseContactShareRepository
/// <-> send_contact on the local stack, wired as main.dart wires it (the chat,
/// reaction, poll and contact-share providers overridden with the Supabase
/// repositories): a sent contact reaches the other member as a contact; a
/// retry with the same id is harmless; a non-member gets DeniedFailure
/// (42501); bad input (22023) is a failure, never a crash. Run with
/// --concurrency=1, TZ=JST-9.
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
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _As extends SessionController {
  _As(this.id);
  final String id;
  @override
  Future<SessionState> build() async =>
      Allowed(Member(userId: id, displayName: id));
}

Failure _failure(Result<void> r) => (r as Err<void>).failure;

void main() {
  late SupabaseClient sanaClient, theoClient, umaClient;
  late String sanaId, theoId;
  late String club;

  Future<ProviderContainer> opened(SupabaseClient client, String id) async {
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
        reactionRepositoryProvider.overrideWithValue(
          SupabaseReactionRepository(client),
        ),
        pollRepositoryProvider.overrideWithValue(
          SupabasePollRepository(client),
        ),
        contactShareRepositoryProvider.overrideWithValue(
          SupabaseContactShareRepository(client),
        ),
        sessionControllerProvider.overrideWith(() => _As(id)),
      ],
    );
    addTearDown(c.dispose);
    await settled(c);
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open(club);
    await c.read(messagesProvider.future);
    return c;
  }

  Future<List<Message>> stored(SupabaseClient as) async {
    final r = await SupabaseChatRepository(as).messages(club);
    expect(r, isA<Ok<List<Message>>>(), reason: '$r');
    return (r as Ok<List<Message>>).value;
  }

  String stamp() => '${DateTime.now().microsecondsSinceEpoch}';

  setUpAll(() async {
    sanaClient = await _signedIn('sana@integration.test');
    theoClient = await _signedIn('theo@integration.test');
    umaClient = await _signedIn('uma@integration.test');
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;
    final sanaChat = SupabaseChatRepository(sanaClient);
    final title = 'contact seam ${stamp()}';
    var r = await sanaChat.startGroupConversation(
      title: title,
      memberIds: [theoId],
    );
    if (r is Err<String>) {
      // Reach only when missing: find_by_tag is rate limited.
      await findByTag(sanaClient, [theoClient]);
      r = await sanaChat.startGroupConversation(
        title: title,
        memberIds: [theoId],
      );
    }
    club = (r as Ok<String>).value;
  });

  tearDown(() async {
    for (final c in [sanaClient, theoClient, umaClient]) {
      await c.removeAllChannels();
    }
  });

  tearDownAll(() async {
    for (final c in [sanaClient, theoClient, umaClient]) {
      await c.dispose();
    }
  });

  test('sendContact through the controller stores a contact the other member '
      'reads', () async {
    final contact = SharedContact(
      name: 'Ann Lee ${stamp()}',
      phone: '+90 555 123',
    );
    final sana = await opened(sanaClient, sanaId);
    final r = await sana.read(messagesProvider.notifier).sendContact(contact);
    expect(r, isA<Ok<void>>(), reason: '$r');
    final mine = sana
        .read(messagesProvider)
        .requireValue
        .where((m) => m.body == contact.body)
        .toList();
    expect(mine, hasLength(1));
    expect(mine.single.contact, isTrue);
    expect(mine.single.sending, isFalse);
    final theirs = (await stored(theoClient))
        .where((m) => m.body == contact.body)
        .toList();
    expect(theirs, hasLength(1));
    expect(theirs.single.id, mine.single.id);
    expect(theirs.single.contact, isTrue);
    expect(theirs.single.senderId, sanaId);
  });

  test('a retry with the same id is harmless', () async {
    final repo = SupabaseContactShareRepository(sanaClient);
    final id = randomMessageId();
    final contact = SharedContact(
      name: 'Retry ${stamp()}',
      phone: '+90 555 777',
    );
    expect(await repo.send(club, id, contact), isA<Ok<void>>());
    final again = await repo.send(club, id, contact);
    expect(again, isA<Ok<void>>(), reason: '$again');
    final rows = (await stored(theoClient)).where((m) => m.id == id).toList();
    expect(rows, hasLength(1));
    expect(rows.single.body, contact.body);
    expect(rows.single.contact, isTrue);
  });

  test('a non-member is refused as DeniedFailure (42501)', () async {
    final id = randomMessageId();
    final r = await SupabaseContactShareRepository(umaClient)
        .send(club, id, const SharedContact(name: 'Ann', phone: '+90 555 123'));
    expect(_failure(r), isA<DeniedFailure>());
    expect((await stored(theoClient)).any((m) => m.id == id), isFalse);
  });

  test('bad input (22023) is a failure, not a crash', () async {
    final repo = SupabaseContactShareRepository(sanaClient);
    for (final bad in const [
      SharedContact(name: '', phone: '+90 555'),
      SharedContact(name: 'Ann', phone: '12'),
      SharedContact(name: 'Ann', phone: '+90\n555'),
    ]) {
      final id = randomMessageId();
      final r = await repo.send(club, id, bad);
      expect(r, isA<Err<void>>(), reason: '${bad.name}/${bad.phone}');
      expect(_failure(r), isNot(isA<DeniedFailure>()), reason: bad.phone);
      expect((await stored(theoClient)).any((m) => m.id == id), isFalse);
    }
  });
}
