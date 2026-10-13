@Tags(['integration'])
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_location_share_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/dead_host.dart';
import '../support/video_fakes.dart';

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

String stamp() => '${DateTime.now().microsecondsSinceEpoch}';

Future<void> until(bool Function() done, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

late SupabaseClient sanaClient, theoClient, umaClient;
late String sanaId, theoId;
late String club;
late String direct;

ProviderContainer c(SupabaseClient client) {
  final container = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(
        SupabaseChatRepository(sanaClient),
      ),
      locationShareRepositoryProvider.overrideWithValue(
        SupabaseLocationShareRepository(client),
      ),
      sessionControllerProvider.overrideWith(() => _As(sanaId)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(() async {
    sanaClient = await _signedIn('fl-sana@integration.test');
    theoClient = await _signedIn('fl-theo@integration.test');
    umaClient = await _signedIn('fl-uma@integration.test');
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;

    final sanaChat = SupabaseChatRepository(sanaClient);
    final title = 'location seam ${stamp()}';
    var r = await sanaChat.startGroupConversation(
      title: title,
      memberIds: [theoId],
    );
    if (r is Err<String>) {
      await findByTag(sanaClient, [theoClient]);
      r = await sanaChat.startGroupConversation(
        title: title,
        memberIds: [theoId],
      );
    }
    club = (r as Ok<String>).value;

    final d = await sanaChat.startDirectConversation(theoId);
    if (d is Err<String>) {
      await findByTag(sanaClient, [theoClient]);
      final d2 = await sanaChat.startDirectConversation(theoId);
      direct = (d2 as Ok<String>).value;
    } else {
      direct = (d as Ok<String>).value;
    }
  });

  tearDownAll(() async {
    for (final c in [sanaClient, theoClient, umaClient]) {
      await c.removeAllChannels();
      await c.dispose();
    }
  });

  test(
    'a location sent through the queue reaches the other group member',
    () async {
      final loc = SharedLocation(
        lat: 40.98765,
        lng: 29.02345,
        name: 'Moda Pier',
        address: 'Kadikoy, Istanbul',
      );
      final container = c(sanaClient);
      await settled(container);
      container.listen(sendQueueProvider, (_, _) {});
      final m = container
          .read(sendQueueProvider.notifier)
          .enqueueLocation(club, loc);
      expect(m.sending, isTrue);
      expect(m.location, isNotNull);
      await until(
        () => (container.read(sendQueueProvider)[club] ?? const <Message>[])
            .isEmpty,
        'the queue to send the location',
      );

      final r = await SupabaseChatRepository(theoClient).messages(club);
      final theirs = (r as Ok<List<Message>>).value.singleWhere(
        (x) => x.id == m.id,
      );
      expect(theirs.senderId, sanaId);
      expect(theirs.location!.lat, 40.98765);
      expect(theirs.location!.lng, 29.02345);
      expect(theirs.location!.name, 'Moda Pier');
      expect(theirs.location!.address, 'Kadikoy, Istanbul');
      expect(previewText(theirs), locationPreviewText);
    },
  );

  test(
    'a location sent through the queue reaches the other 1:1 member',
    () async {
      final loc = SharedLocation(
        lat: 51.5074,
        lng: -0.1278,
        name: 'Here',
        address: '',
      );
      final container = c(sanaClient);
      await settled(container);
      container.listen(sendQueueProvider, (_, _) {});
      final m = container
          .read(sendQueueProvider.notifier)
          .enqueueLocation(direct, loc);
      expect(m.sending, isTrue);
      expect(m.location, isNotNull);
      await until(
        () => (container.read(sendQueueProvider)[direct] ?? const <Message>[])
            .isEmpty,
        'the queue to send the location',
      );

      final r = await SupabaseChatRepository(theoClient).messages(direct);
      final theirs = (r as Ok<List<Message>>).value.singleWhere(
        (x) => x.id == m.id,
      );
      expect(theirs.senderId, sanaId);
      expect(theirs.location!.name, 'Here');
      expect(theirs.location!.address, '');
      expect(previewText(theirs), locationPreviewText);
    },
  );

  test('the server refuses a non-member', () async {
    final loc = SharedLocation(lat: 1.0, lng: 2.0, name: 'X', address: '');
    final id = randomMessageId();
    final send = await SupabaseLocationShareRepository(umaClient)
        .send(club, id, loc);
    expect(send, isA<Err<void>>());
    expect((send as Err<void>).failure, isA<DeniedFailure>());

    final r = await SupabaseChatRepository(theoClient).messages(club);
    final msgs = (r as Ok<List<Message>>).value;
    expect(msgs.any((m) => m.id == id), isFalse);
  });

  test('a retry with the same id is harmless', () async {
    final loc = SharedLocation(
      lat: 10.0,
      lng: 20.0,
      name: 'Retry',
      address: '',
    );
    final id = randomMessageId();
    final repo = SupabaseLocationShareRepository(sanaClient);
    final r1 = await repo.send(club, id, loc);
    final r2 = await repo.send(club, id, loc);
    expect(r1, isA<Ok<void>>());
    expect(r2, isA<Ok<void>>());

    final r = await SupabaseChatRepository(theoClient).messages(club);
    final msgs = (r as Ok<List<Message>>).value;
    expect(msgs.where((m) => m.id == id).length, 1);
  });

  test('offline: the queue keeps it and sends it when back', () async {
    final dead = await deadButSignedIn(sanaClient);
    final container = c(dead);
    await settled(container);
    container.listen(sendQueueProvider, (_, _) {});
    final loc = SharedLocation(
      lat: 0.0,
      lng: 0.0,
      name: 'Offline',
      address: '',
    );
    final m = container
        .read(sendQueueProvider.notifier)
        .enqueueLocation(club, loc);
    await Future<void>.delayed(const Duration(seconds: 2));
    final queue = container.read(sendQueueProvider)[club] ?? const <Message>[];
    expect(queue.any((msg) => msg.id == m.id), isTrue);
    final r = await SupabaseChatRepository(theoClient).messages(club);
    final msgs = (r as Ok<List<Message>>).value;
    expect(msgs.any((msg) => msg.id == m.id), isFalse);
  });
}
