@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';

/// Image attachments against the real stack: a real upload into a private
/// bucket, real storage row-level security, a real signed URL fetched over
/// HTTP, and the real relaxed check constraint on `messages`.
///
/// This is the half no fake can reach. A bucket that was never created, a
/// policy that reads the wrong path segment, a signed URL that is issued but
/// serves 400, a check constraint that still refuses an empty caption — every
/// one of those passes the unit tests and fails on a device.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts: signing in claims the active device, so sharing a pair with
/// another suite would evict it.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A host that accepts nothing: the honest form of "the connection failed".
const _deadUrl = 'http://127.0.0.1:1';

/// A real 1x1 PNG. Real bytes, because the bucket checks the mime type and
/// the HTTP round trip below compares what came back with what went up.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage _image({String contentType = 'image/png', String ext = 'png'}) =>
    PickedImage(bytes: _png, contentType: contentType, extension: ext);

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

/// Fetches [uri] the way an image widget would. A signed URL that cannot be
/// fetched is a broken attachment however well-formed it looks.
Future<({int status, Uint8List body})> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await client.getUrl(uri).then((r) => r.close());
    final bytes = await response.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    return (status: response.statusCode, body: Uint8List.fromList(bytes));
  } finally {
    client.close(force: true);
  }
}

void main() {
  SupabaseClient? liamClient;
  SupabaseClient? miaClient;
  SupabaseClient? noahClient;
  SupabaseClient? deadClient;
  late SupabaseChatRepository liam;
  late SupabaseChatRepository mia;
  late SupabaseChatRepository noah;
  late SupabaseChatRepository offline;
  late String conversationId;

  setUpAll(() async {
    noahClient = await _signedIn('noah@integration.test');
    miaClient = await _signedIn('mia@integration.test');
    liamClient = await _signedIn('liam@integration.test');
    deadClient = _client(_deadUrl);
    liam = SupabaseChatRepository(liamClient!);
    mia = SupabaseChatRepository(miaClient!);
    noah = SupabaseChatRepository(noahClient!);
    offline = SupabaseChatRepository(deadClient!);

    final started = await liam.startDirectConversation(
      miaClient!.auth.currentUser!.id,
    );
    expect(started, isA<Ok<String>>());
    conversationId = (started as Ok<String>).value;
  });

  tearDownAll(() async {
    await liamClient?.dispose();
    await miaClient?.dispose();
    await noahClient?.dispose();
    await deadClient?.dispose();
  });

  test('an image is uploaded into the conversation folder and sent', () async {
    final caption = 'caption ${DateTime.now().microsecondsSinceEpoch}';
    final sent = await liam.sendImage(
      conversationId: conversationId,
      image: _image(),
      body: caption,
    );

    expect(sent, isA<Ok<Message>>(), reason: 'the real upload was refused');
    final message = (sent as Ok<Message>).value;
    expect(message.body, caption);
    expect(message.hasAttachment, isTrue);
    expect(message.conversationId, conversationId);
    expect(
      message.attachmentPath!.split('/').first,
      conversationId,
      reason: 'the first path segment is what the storage policy authorises',
    );
  });

  test('an image with no caption is accepted by the real constraint', () async {
    final sent = await liam.sendImage(
      conversationId: conversationId,
      image: _image(),
    );

    expect(
      sent,
      isA<Ok<Message>>(),
      reason: 'messages_body_check must allow an empty body with an image',
    );
    expect((sent as Ok<Message>).value.body, isEmpty);
    expect(sent.value.hasAttachment, isTrue);
  });

  test('the other member reads it and gets a working signed URL', () async {
    final caption = 'shared ${DateTime.now().microsecondsSinceEpoch}';
    final sent = await liam.sendImage(
      conversationId: conversationId,
      image: _image(),
      body: caption,
    ) as Ok<Message>;

    final theirs = await mia.messages(conversationId);
    final seen = (theirs as Ok<List<Message>>).value.firstWhere(
      (m) => m.body == caption,
      orElse: () => fail('the other member cannot see the image message'),
    );
    expect(
      seen.attachmentPath,
      sent.value.attachmentPath,
      reason: 'attachment_path must survive the round trip through the column',
    );

    final url = await mia.attachmentUrl(seen.attachmentPath!);
    expect(url, isA<Ok<Uri>>(), reason: 'a member must be able to sign it');

    final fetched = await _get((url as Ok<Uri>).value);
    expect(
      fetched.status,
      200,
      reason: 'a signed URL that cannot be fetched is a broken attachment',
    );
    expect(
      fetched.body,
      _png,
      reason: 'the bytes served must be the bytes uploaded',
    );
  });

  test(
    'a non-member can neither read the message nor sign the object',
    () async {
      final caption = 'private ${DateTime.now().microsecondsSinceEpoch}';
      final sent = await liam.sendImage(
        conversationId: conversationId,
        image: _image(),
        body: caption,
      ) as Ok<Message>;
      final path = sent.value.attachmentPath!;

      // noah is allowlisted AND holds an active session, so has_app_access() is
      // true for him: only the conversation in the object key can stop him.
      final his = await noah.messages(conversationId);
      expect((his as Ok<List<Message>>).value, isEmpty);

      final url = await noah.attachmentUrl(path);
      expect(
        url,
        isA<Err<Uri>>(),
        reason:
            'a non-member signed an object in somebody else\'s conversation',
      );
    },
  );

  test('a non-member cannot upload into the conversation folder', () async {
    final result = await noah.sendImage(
      conversationId: conversationId,
      image: _image(),
      body: 'gatecrashing',
    );
    expect(result, isA<Err<Message>>());

    final after = await liam.messages(conversationId);
    expect(
      (after as Ok<List<Message>>).value.map((m) => m.body),
      isNot(contains('gatecrashing')),
    );
  });

  test('the bucket refuses a type that is not an image', () async {
    final result = await liam.sendImage(
      conversationId: conversationId,
      image: _image(contentType: 'application/pdf', ext: 'pdf'),
      body: 'not an image',
    );

    expect(
      result,
      isA<Err<Message>>(),
      reason: 'the bucket accepts only jpeg, png, webp and gif',
    );
    final after = await liam.messages(conversationId);
    expect(
      (after as Ok<List<Message>>).value.map((m) => m.body),
      isNot(contains('not an image')),
      reason: 'a refused upload must not leave a message behind',
    );
  });

  test('an unreachable server is an Err, not a thrown exception', () async {
    expect(
      await offline.sendImage(
        conversationId: conversationId,
        image: _image(),
        body: 'never arrives',
      ),
      isA<Err<Message>>(),
    );
    expect(
      await offline.attachmentUrl('$conversationId/x.png'),
      isA<Err<Uri>>(),
    );
  });

  test('a path in no conversation at all cannot be signed', () async {
    expect(
      await liam.attachmentUrl('not-a-uuid/photo.png'),
      isA<Err<Uri>>(),
      reason: 'a malformed key must be refused, not raise a 500',
    );
  });

  group('the controller seam', () {
    /// Mounted the way production mounts it: the real repository behind
    /// [chatRepositoryProvider], the picker behind [attachmentSourceProvider].
    ProviderContainer containerFor(
      SupabaseChatRepository repository,
      AttachmentSource picker,
    ) => ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(repository),
        attachmentSourceProvider.overrideWithValue(picker),
      ],
    );

    test(
      'sendImage appends a real message the other member can read',
      () async {
        final container = containerFor(
          liam,
          PickerFake.returns(
            PickedImage(
              bytes: _png,
              contentType: 'image/png',
              extension: 'png',
            ),
          ),
        );
        container.read(openConversationProvider.notifier).open(conversationId);
        await container.read(messagesProvider.future);

        final caption = 'seam ${DateTime.now().microsecondsSinceEpoch}';
        final result = await container
            .read(messagesProvider.notifier)
            .sendImage(body: caption);

        expect(result, isA<Ok<Message>>());
        final appended = container.read(messagesProvider).requireValue;
        expect(
          appended.map((m) => m.id),
          contains((result! as Ok<Message>).value.id),
          reason: 'the sender must see their own image immediately',
        );

        final theirs = await mia.messages(conversationId);
        expect(
          (theirs as Ok<List<Message>>).value.map((m) => m.body),
          contains(caption),
        );
      },
    );

    test('a cancelled picker is null and sends nothing', () async {
      final picker = PickerFake.cancels();
      final container = containerFor(liam, picker);
      container.read(openConversationProvider.notifier).open(conversationId);
      final before = (await container.read(messagesProvider.future)).length;

      final result = await container
          .read(messagesProvider.notifier)
          .sendImage(body: 'never sent');

      expect(result, isNull);
      expect(picker.calls, 1);
      expect(container.read(messagesProvider).requireValue, hasLength(before));
      final theirs = await mia.messages(conversationId);
      expect(
        (theirs as Ok<List<Message>>).value.map((m) => m.body),
        isNot(contains('never sent')),
      );
    });

    test(
      'the failure path of the upload connection reaches the caller',
      () async {
        final container = containerFor(
          offline,
          PickerFake.returns(
            PickedImage(
              bytes: _png,
              contentType: 'image/png',
              extension: 'png',
            ),
          ),
        );
        container.read(openConversationProvider.notifier).open(conversationId);
        container.listen(messagesProvider, (_, _) {});
        await Future<void>.delayed(const Duration(seconds: 1));

        final result = await container
            .read(messagesProvider.notifier)
            .sendImage(body: 'offline');

        expect(result, isA<Err<Message>>());
        expect(
          (result! as Err<Message>).failure.message.trim(),
          isNotEmpty,
          reason: 'a failure with no reason cannot be shown to anybody',
        );
      },
    );
  });
}
