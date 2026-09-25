@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/service_key.dart';
import '../support/dead_host.dart';

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

// The service_role key: bypasses RLS, the only way left to create a message
// pointing at a photo that was never uploaded (messages_send now requires the
// sender to own a real storage object at attachment_path) -- a state a real
// client can no longer reach, but the one this fixture needs to exist so the
// read side's handling of a dangling reference is still exercised.

/// A real 1x1 PNG. Real bytes, because the bucket checks the mime type and
/// the HTTP round trip below compares what came back with what went up.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage _image({String contentType = 'image/png', String ext = 'png'}) =>
    PickedImage(bytes: _png, contentType: contentType, extension: ext);

/// An [AttachmentCache] kept in memory, shared between two repositories so a
/// test can prove the second one served a read from it, never the network.
class _MemoryCache implements AttachmentCache {
  final _store = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String path) async => _store[path];

  @override
  Future<void> write(String path, Uint8List bytes) async {
    _store[path] = bytes;
  }

  @override
  Future<void> remove(String path) async => _store.remove(path);

  @override
  Future<void> clear() async => _store.clear();
}

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

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

/// Text a member may be shown: a reason, never the SDK's own rendering.
void _expectReadable(Failure failure) {
  expect(failure.message.trim(), isNotEmpty);
  for (final raw in ['Exception', 'statusCode', 'not_found', 'Instance of']) {
    expect(
      failure.message,
      isNot(contains(raw)),
      reason: 'raw SDK text would reach the screen: ${failure.message}',
    );
  }
}

void main() {
  // The widget test below needs the binding, and the binding answers every
  // HTTP request with 400 unless told otherwise: this suite talks to a real
  // server, so it gets the real network.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

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
    deadClient = deadHostClient();
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
    /// [chatRepositoryProvider]. The photo comes from the attachment sheet,
    /// which hands sendImage what the member chose.
    ProviderContainer containerFor(SupabaseChatRepository repository) =>
        ProviderContainer.test(
          overrides: [chatRepositoryProvider.overrideWithValue(repository)],
        );

    test(
      'sendImage appends a real message the other member can read',
      () async {
        final container = containerFor(liam);
        container.read(openConversationProvider.notifier).open(conversationId);
        await container.read(messagesProvider.future);

        final caption = 'seam ${DateTime.now().microsecondsSinceEpoch}';
        final result = await container
            .read(messagesProvider.notifier)
            .sendImage(
              body: caption,
              chosen: PickedImage(
                bytes: _png,
                contentType: 'image/png',
                extension: 'png',
              ),
            );

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

    test(
      'attachmentUrlProvider serves the viewer a URL that fetches the bytes',
      () async {
        final sent = await liam.sendImage(
          conversationId: conversationId,
          image: _image(),
        ) as Ok<Message>;
        final path = sent.value.attachmentPath!;

        // The other member opens it, as the photo viewer does.
        final container = containerFor(mia);
        final sub = container.listen(attachmentUrlProvider(path), (_, _) {});
        final url = await container.read(attachmentUrlProvider(path).future);

        final fetched = await _get(url);
        expect(fetched.status, 200);
        expect(fetched.body, _png);
        sub.close();
      },
    );

    test('attachmentUrlProvider carries the refusal as a Failure', () async {
      final sent = await liam.sendImage(
        conversationId: conversationId,
        image: _image(),
      ) as Ok<Message>;
      final path = sent.value.attachmentPath!;

      for (final repository in [noah, offline]) {
        final container = containerFor(repository);
        container.listen(attachmentUrlProvider(path), (_, _) {});

        await expectLater(
          container.read(attachmentUrlProvider(path).future),
          throwsA(isA<Failure>()),
          reason: 'the viewer can only show a reason it is handed',
        );
        final state = container.read(attachmentUrlProvider(path));
        expect(state, isA<AsyncError<Uri>>());
        expect((state.error! as Failure).message.trim(), isNotEmpty);
      }
    });

    test('nothing chosen is null and sends nothing', () async {
      final container = containerFor(liam);
      container.read(openConversationProvider.notifier).open(conversationId);
      final before = (await container.read(messagesProvider.future)).length;

      final result = await container
          .read(messagesProvider.notifier)
          .sendImage(body: 'never sent');

      expect(result, isNull);
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
        final container = containerFor(offline);
        container.read(openConversationProvider.notifier).open(conversationId);
        container.listen(messagesProvider, (_, _) {});
        await Future<void>.delayed(const Duration(seconds: 1));

        final result = await container
            .read(messagesProvider.notifier)
            .sendImage(
              body: 'offline',
              chosen: PickedImage(
                bytes: _png,
                contentType: 'image/png',
                extension: 'png',
              ),
            );

        expect(result, isA<Err<Message>>());
        expect(
          (result! as Err<Message>).failure.message.trim(),
          isNotEmpty,
          reason: 'a failure with no reason cannot be shown to anybody',
        );
      },
    );
  });

  group('attachmentBytes and the cache', () {
    test(
      'downloads a photo a member can see and writes it to the cache',
      () async {
        final cache = _MemoryCache();
        final reader = SupabaseChatRepository(miaClient!, cache: cache);
        final sent = await liam.sendImage(
          conversationId: conversationId,
          image: _image(),
        ) as Ok<Message>;
        final path = sent.value.attachmentPath!;

        final result = await reader.attachmentBytes(path);

        expect(result, isA<Ok<Uint8List>>());
        expect((result as Ok<Uint8List>).value, _png);
        expect(
          await cache.read(path),
          _png,
          reason: 'the downloaded bytes must be written to the cache',
        );
      },
    );

    test(
      'a second call is served from the cache, without the network',
      () async {
        final cache = _MemoryCache();
        final live = SupabaseChatRepository(miaClient!, cache: cache);
        final sent = await liam.sendImage(
          conversationId: conversationId,
          image: _image(),
        ) as Ok<Message>;
        final path = sent.value.attachmentPath!;
        expect(await live.attachmentBytes(path), isA<Ok<Uint8List>>());

        // Same cache, but a repository over a client that cannot reach
        // anything at all: succeeding here can only mean the second read
        // never touched the network.
        final dead = SupabaseChatRepository(deadClient!, cache: cache);
        final second = await dead.attachmentBytes(path);

        expect(second, isA<Ok<Uint8List>>());
        expect((second as Ok<Uint8List>).value, _png);
      },
    );

    test('a non-member is refused with a readable reason', () async {
      final sent = await liam.sendImage(
        conversationId: conversationId,
        image: _image(),
      ) as Ok<Message>;
      final path = sent.value.attachmentPath!;
      final reader = SupabaseChatRepository(noahClient!);

      final result = await reader.attachmentBytes(path);

      // The storage API answers the same way for "not yours" and "gone"
      // (both are a 404 from the object store the RLS check hides behind);
      // _asFailure maps both to the same readable NetworkFailure, exactly
      // as attachmentUrl already does for the same object.
      expect(result, isA<Err<Uint8List>>());
      _expectReadable((result as Err<Uint8List>).failure);
    });
  });

  group('attachment_preview round trip', () {
    test('sendImage stores it, and it comes back through messages() for the '
        'other member', () async {
      final image = PickedImage(
        bytes: _png,
        contentType: 'image/png',
        extension: 'png',
        preview: _png,
      );
      final caption = 'preview ${DateTime.now().microsecondsSinceEpoch}';
      final sent = await liam.sendImage(
        conversationId: conversationId,
        image: image,
        body: caption,
      ) as Ok<Message>;
      expect(sent.value.attachmentPreview, _png);

      final theirs = await mia.messages(conversationId);
      final seen = (theirs as Ok<List<Message>>).value.firstWhere(
        (m) => m.id == sent.value.id,
      );
      expect(
        seen.attachmentPreview,
        _png,
        reason: 'the preview must survive the round trip through the row',
      );
    });

    test('arrives on incoming() for the other member too', () async {
      final subscribed = await mia.incoming(conversationId);
      expect(subscribed, isA<Ok<Stream<Message>>>());
      final stream = (subscribed as Ok<Stream<Message>>).value;

      final image = PickedImage(
        bytes: _png,
        contentType: 'image/png',
        extension: 'png',
        preview: _png,
      );
      final caption =
          'incoming preview ${DateTime.now().microsecondsSinceEpoch}';
      final sent = await liam.sendImage(
        conversationId: conversationId,
        image: image,
        body: caption,
      ) as Ok<Message>;

      // Filtered by id, not "first": a still-in-flight broadcast for a
      // message an earlier test sent into the same conversation can arrive
      // just after this subscription joins, and must not be mistaken for
      // this one.
      final message = await stream
          .firstWhere((m) => m.id == sent.value.id)
          .timeout(const Duration(seconds: 15));
      expect(message.attachmentPreview, _png);
    });

    test('a PickedImage with no preview sends none', () async {
      final sent = await liam.sendImage(
        conversationId: conversationId,
        image: _image(),
      ) as Ok<Message>;
      expect(sent.value.attachmentPreview, isNull);

      final theirs = await mia.messages(conversationId);
      final seen = (theirs as Ok<List<Message>>).value.firstWhere(
        (m) => m.id == sent.value.id,
      );
      expect(seen.attachmentPreview, isNull);
    });
  });

  // Last in the file: its Realtime socket is closed on the way out.
  group('a photo storage cannot serve', () {
    late String groupId;
    late String missingPath;
    late String realPath;
    late Member miaMember;

    setUpAll(() async {
      final miaId = miaClient!.auth.currentUser!.id;
      miaMember = Member(userId: miaId, displayName: 'Mia');
      final started = await liam.startGroupConversation(
        title: 'photos ${DateTime.now().microsecondsSinceEpoch}',
        memberIds: [miaId],
      );
      groupId = (started as Ok<String>).value;

      // A message whose object was never stored, or has since gone: the row
      // is readable, the object is not, and storage answers 404. No client
      // insert can create this any more (messages_send now checks
      // ownership of a real object), so it is written with the service
      // role, the way it could still arise for real -- the object was
      // removed after the message was sent.
      missingPath = '$groupId/never-uploaded.png';
      final service = SupabaseClient(
        _url,
        serviceKey(),
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );
      addTearDown(service.dispose);
      await service.from('messages').insert({
        'conversation_id': groupId,
        'sender_id': liamClient!.auth.currentUser!.id,
        'body': '',
        'attachment_path': missingPath,
      });
      final sent = await liam.sendImage(
        conversationId: groupId,
        image: _image(),
      ) as Ok<Message>;
      realPath = sent.value.attachmentPath!;
    });

    test('storage refusals come back as readable Failures', () async {
      final missing = await mia.attachmentUrl(missingPath);
      expect(missing, isA<Err<Uri>>(), reason: 'a missing object was signed');
      _expectReadable((missing as Err<Uri>).failure);

      final foreign = await noah.attachmentUrl(realPath);
      expect(foreign, isA<Err<Uri>>(), reason: 'a non-member signed it');
      _expectReadable((foreign as Err<Uri>).failure);

      final container = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(noah)],
      );
      container.listen(attachmentUrlProvider(realPath), (_, _) {});
      await expectLater(
        container.read(attachmentUrlProvider(realPath).future),
        throwsA(isA<Failure>()),
      );
      _expectReadable(
        container.read(attachmentUrlProvider(realPath)).error! as Failure,
      );
    });

    testWidgets('the bubble and the viewer show that reason', (t) async {
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);

      Future<void> until(bool Function() ok, String what) async {
        for (var i = 0; i < 150; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await t.pump();
          if (ok()) return;
        }
        fail('never happened: $what');
      }

      final refused = (await t.runAsync(() => mia.attachmentUrl(missingPath)))!;
      final reason = (refused as Err<Uri>).failure.message;

      // Mounted as production mounts the screen: real repositories for
      // everything that reaches the server.
      final container = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(mia),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(miaClient!),
          ),
          linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
          sessionControllerProvider.overrideWith(() => _SignedIn(miaMember)),
        ],
      );
      // The account settles first: settling resets the open conversation.
      await t.runAsync(() => settled(container));
      container.read(openConversationProvider.notifier).open(groupId);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: sisTheme(Brightness.light),
            home: const MessageScreen(title: 'photos'),
          ),
        ),
      );

      final raw = find.byWidgetPredicate((w) {
        final text = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
        return text != null &&
            (text.contains('Exception') || text.contains('statusCode'));
      });

      await until(
        () => find.textContaining(reason).evaluate().isNotEmpty,
        'the bubble never showed why the photo is missing',
      );
      expect(raw, findsNothing);

      final photo = find.byKey(ValueKey('attachment-$realPath'));
      await until(() => photo.evaluate().isNotEmpty, 'the real photo');
      await t.tap(photo);
      await until(
        () => find.byType(PhotoViewer).evaluate().isNotEmpty,
        'the viewer never opened',
      );
      final inViewer = find.descendant(
        of: find.byType(PhotoViewer),
        matching: find.byKey(const ValueKey('viewer-position')),
      );
      expect(inViewer, findsOneWidget);

      await t.fling(
        find.byKey(const ValueKey('viewer-pages')),
        const Offset(1000, 0),
        2000,
      );
      await until(
        () => find
            .descendant(
              of: find.byType(PhotoViewer),
              matching: find.textContaining(reason),
            )
            .evaluate()
            .isNotEmpty,
        'the viewer page never showed why the photo is missing',
      );
      expect(raw, findsNothing);

      await t.pumpWidget(const SizedBox());
      container.dispose();
      await t.runAsync(() => miaClient!.removeAllChannels());
      await t.runAsync(() => miaClient!.realtime.disconnect());
      await t.pump(const Duration(seconds: 61));
    });
  });
}
