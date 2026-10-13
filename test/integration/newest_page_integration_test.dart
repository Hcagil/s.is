@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/reach.dart';
import '../support/video_fakes.dart';

/// The newest-page open (0.30.14) against the real local stack:
/// - messages() is the newest messagePageSize rows, oldest first, with no
///   preview bytes on any row;
/// - attachmentPreviews() returns the stored preview of each photo asked
///   for, nothing for a text row or a photo without one, no query for an
///   empty list, and an Err when the server cannot be reached;
/// - MessagesController.loadOlder() over the real messagesAround pages a
///   chat longer than two pages with no gap and no duplicate, and stops.
///
/// A fake cannot show any of this: the page size, the column left out of the
/// first read and the batched preview query are PostgREST query shaping.
///
/// Requires `docker compose run --rm supabase start`. nami and odo are this
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

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _total = 130;

/// Photo rows by index; those mapped to true carry a preview. 5 is older
/// than the newest page; the rest are in it.
const _photos = {5: true, 85: true, 95: false, 100: true, 125: true};

/// A distinct preview per row: the server accepts only real image bytes, so
/// each is the PNG with the row's own trailing marker.
Uint8List _previewFor(int i) => Uint8List.fromList([..._png, i, 255 - i]);

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

void main() {
  late SupabaseClient odoClient;
  late SupabaseClient namiClient;
  late SupabaseChatRepository nami;
  late String chat;

  /// Message ids by index, oldest first.
  final ids = <String>[];

  setUpAll(() async {
    odoClient = await _signedIn('odo@integration.test');
    namiClient = await _signedIn('nami@integration.test');
    nami = SupabaseChatRepository(namiClient);
    final odo = SupabaseChatRepository(odoClient);
    await findByTag(odoClient, [namiClient]);
    // A group, because it is always a fresh conversation: a rerun must not
    // find the previous run's rows in it.
    chat = _ok(
      await odo.startGroupConversation(
        title: 'pages ${DateTime.now().microsecondsSinceEpoch}',
        memberIds: [namiClient.auth.currentUser!.id],
      ),
    );
    // One write per row: created_at is the transaction's now(), so a single
    // insert of every row would stamp them all alike and "older" would mean
    // nothing.
    final sender = odoClient.auth.currentUser!.id;
    for (var i = 0; i < _total; i++) {
      if (_photos[i] case final withPreview?) {
        final sent = _ok(
          await odo.sendImage(
            conversationId: chat,
            image: PickedImage(
              bytes: _png,
              contentType: 'image/png',
              extension: 'png',
              preview: withPreview ? _previewFor(i) : null,
            ),
          ),
        );
        ids.add(sent.id);
      } else {
        final id = randomMessageId();
        await odoClient.from('messages').insert({
          'id': id,
          'conversation_id': chat,
          'sender_id': sender,
          'body': 'page-row $i',
        });
        ids.add(id);
      }
    }
  });

  tearDownAll(() async {
    await odoClient.dispose();
    await namiClient.dispose();
  });

  group('messages()', () {
    test('the newest page only, oldest first, without previews', () async {
      final rows = _ok(await nami.messages(chat));
      expect(rows, hasLength(messagePageSize));
      expect(
        rows.map((m) => m.id).toList(),
        ids.sublist(_total - messagePageSize),
        reason: 'exactly the newest $messagePageSize, oldest first',
      );
      expect(
        rows.where((m) => m.attachmentPreview != null).map((m) => m.id),
        isEmpty,
        reason: 'previews come only from attachmentPreviews',
      );
      expect(
        rows.where((m) => m.hasAttachment),
        hasLength(4),
        reason: 'the photos in the page are still photos',
      );
    });
  });

  group('attachmentPreviews()', () {
    test('the stored bytes of each photo with a preview; a text row and a '
        'photo without one are absent', () async {
      final asked = [ids[85], ids[95], ids[81], ids[5], ids[125]];
      final previews = _ok(await nami.attachmentPreviews(asked));
      expect(previews.keys.toSet(), {ids[85], ids[5], ids[125]});
      expect(previews[ids[85]], _previewFor(85));
      expect(previews[ids[5]], _previewFor(5));
      expect(previews[ids[125]], _previewFor(125));
    });

    test('an empty list is Ok and empty without asking the server', () async {
      // A dead host: any query at all would fail.
      final dead = await deadButSignedIn(namiClient);
      addTearDown(dead.dispose);
      final r = await SupabaseChatRepository(dead).attachmentPreviews(const []);
      expect(r, isA<Ok<Map<String, Uint8List>>>());
      expect((r as Ok<Map<String, Uint8List>>).value, isEmpty);
    });

    test('an unreachable server is an Err, not a throw', () async {
      final dead = await deadButSignedIn(namiClient);
      addTearDown(dead.dispose);
      final r = await SupabaseChatRepository(dead)
          .attachmentPreviews([ids[85]]);
      expect(r, isA<Err<Map<String, Uint8List>>>());
    });

    test('another member\'s chat yields nothing', () async {
      // Row-level security applies: a stranger asking by id gets no bytes.
      final stranger = await _signedIn('pim@integration.test');
      addTearDown(stranger.dispose);
      final r = await SupabaseChatRepository(stranger)
          .attachmentPreviews([ids[85]]);
      expect(_ok(r), isEmpty);
    });
  });

  group('the controller over the real repository', () {
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(nami),
        ],
      );
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open(chat);
    });

    tearDown(() => c.dispose());

    List<Message> shown() => c.read(messagesProvider).value ?? const [];

    test('opens on the newest page, then the previews arrive by id', () async {
      await c.read(messagesProvider.future);
      expect(shown().map((m) => m.id), ids.sublist(_total - messagePageSize));
      await _eventually(
        () =>
            shown().any((m) => m.id == ids[85] && m.attachmentPreview != null),
        reason: 'the batched previews never reached the rows',
      );
      Message row(int i) => shown().firstWhere((m) => m.id == ids[i]);
      expect(row(85).attachmentPreview, _previewFor(85));
      expect(row(100).attachmentPreview, _previewFor(100));
      expect(row(125).attachmentPreview, _previewFor(125));
      expect(row(95).attachmentPreview, isNull);
    });

    test('loadOlder pages the whole chat: no gap, no duplicate, then '
        'stops', () async {
      await c.read(messagesProvider.future);
      final controller = c.read(messagesProvider.notifier);
      expect(controller.hasOlder, isTrue);
      var guard = 0;
      while (controller.hasOlder) {
        if (++guard > 5) fail('paging never ended: ${shown().length} shown');
        await controller.loadOlder();
      }
      expect(
        shown().map((m) => m.id).toList(),
        ids,
        reason: 'every message once, oldest first, none missing',
      );
      // The older photo came with its preview.
      expect(
        shown().firstWhere((m) => m.id == ids[5]).attachmentPreview,
        _previewFor(5),
      );
    });
  });
}
