@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

/// Photo albums over the real stack (feat/photo-albums): photo_group goes
/// through SupabaseChatRepository into messages.photo_group and back, and
/// MessagesController.sendImages / forwardTo, wired as main.dart wires the
/// chat repository, store and copy albums the way the contract says:
/// one group per album, the caption on its first photo, a NEW group for each
/// forward target, no group on a plain forward.
///
/// Uses priya, quinlan and kai (supabase/seed.sql), on the random local test
/// password (support/service_key.dart); run with --concurrency=1.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

/// A real 1x1 PNG: the bucket checks the mime type against real bytes.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage _photo() =>
    PickedImage(bytes: _png, contentType: 'image/png', extension: 'png');

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

T _ok<T>(Result<T> r, String what) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => throw TestFailure('$what failed: $failure'),
};

void main() {
  HttpOverrides.global = null;

  late SupabaseClient reidClient, bethClient, coraClient;
  late SupabaseChatRepository reid, beth, cora;
  late Member reidMember;
  late String c1; // reid+beth: where albums are sent
  late String c2; // reid+cora: a forward target
  late String g3; // reid+beth+cora group: a second forward target

  setUpAll(() async {
    reidClient = await _signedIn('priya@integration.test');
    bethClient = await _signedIn('quinlan@integration.test');
    coraClient = await _signedIn('kai@integration.test');
    reid = SupabaseChatRepository(reidClient);
    beth = SupabaseChatRepository(bethClient);
    cora = SupabaseChatRepository(coraClient);
    reidMember = Member(
      userId: reidClient.auth.currentUser!.id,
      displayName: 'Reid',
    );
    await findByTag(reidClient, [bethClient, coraClient]);
    c1 = _ok(
      await reid.startDirectConversation(bethClient.auth.currentUser!.id),
      'reid+beth',
    );
    c2 = _ok(
      await reid.startDirectConversation(coraClient.auth.currentUser!.id),
      'reid+cora',
    );
    g3 = _ok(
      await reid.startGroupConversation(
        title: 'album seam ${DateTime.now().microsecondsSinceEpoch}',
        memberIds: [
          bethClient.auth.currentUser!.id,
          coraClient.auth.currentUser!.id,
        ],
      ),
      'group',
    );
  });

  tearDownAll(() async {
    await reidClient.dispose();
    await bethClient.dispose();
    await coraClient.dispose();
  });

  /// Reid's controllers over the real repository, with c1 open and loaded.
  Future<ProviderContainer> reidInC1() async {
    final container = ProviderContainer(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(reid),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(reidMember)),
      ],
    );
    addTearDown(container.dispose);
    await settled(container);
    container.read(openConversationProvider.notifier).open(c1);
    container.listen(messagesProvider, (_, _) {});
    await container.read(messagesProvider.future);
    return container;
  }

  /// The photos in [conversation] as [who] reads them that are not in
  /// [before], oldest first.
  Future<List<Message>> newPhotos(
    SupabaseChatRepository who,
    String conversation,
    Set<String> before,
  ) async => [
    for (final m in _ok(await who.messages(conversation), 'reading'))
      if (m.attachmentPath != null && !before.contains(m.id)) m,
  ];

  Future<Set<String>> ids(SupabaseChatRepository who, String c) async => {
    for (final m in _ok(await who.messages(c), 'reading')) m.id,
  };

  test('repository: photos sent with one group are read back by the other '
      'member with that group; a photo without one reads back null', () async {
    final group = randomMessageId();
    final sent = <Message>[];
    for (var i = 0; i < 3; i++) {
      sent.add(
        _ok(
          await reid.sendImage(
            conversationId: c1,
            image: _photo().inGroup(group),
          ),
          'photo $i',
        ),
      );
    }
    final lone = _ok(
      await reid.sendImage(conversationId: c1, image: _photo()),
      'lone photo',
    );

    expect(sent.map((m) => m.photoGroup), [
      group,
      group,
      group,
    ], reason: 'the insert answer lost the group');
    final read = {
      for (final m in _ok(await beth.messages(c1), 'beth reads')) m.id: m,
    };
    for (final m in sent) {
      expect(read[m.id]?.photoGroup, group, reason: 'beth reads ${m.id}');
    }
    expect(read[lone.id]?.photoGroup, isNull);
  });

  test('controller: sendImages stores one album -- one group, the caption on '
      'its first photo only', () async {
    final before = await ids(beth, c1);
    final container = await reidInC1();
    final caption = 'album ${DateTime.now().microsecondsSinceEpoch}';

    final result = await container.read(messagesProvider.notifier).sendImages([
      _photo(),
      _photo(),
      _photo(),
    ], body: caption);

    expect(result, isA<Ok<void>>(), reason: '$result');
    final stored = await newPhotos(beth, c1, before);
    expect(stored, hasLength(3));
    final group = stored.first.photoGroup;
    expect(group, isNotNull);
    expect(stored.map((m) => m.photoGroup).toSet(), {group});
    expect(stored.map((m) => m.body), [caption, '', '']);
  });

  test('controller: forwardTo with album gives each target every photo under '
      'its own new group; a plain forward carries none', () async {
    final container = await reidInC1();
    final ctl = container.read(messagesProvider.notifier);
    expect(
      await ctl.sendImages([_photo(), _photo()], body: 'to forward'),
      isA<Ok<void>>(),
    );
    final source = [
      for (final m in container.read(messagesProvider).requireValue)
        if (m.attachmentPath != null && !m.isPending) m,
    ].reversed.take(2).toList().reversed.toList();
    final sourceGroup = source.first.photoGroup;
    expect(sourceGroup, isNotNull, reason: 'the album was not loaded back');
    expect(source.last.photoGroup, sourceGroup);

    final beforeC2 = await ids(cora, c2);
    final beforeG3 = await ids(cora, g3);
    final r = await ctl.forwardTo(
      source.first,
      conversationIds: [c2, g3],
      album: true,
    );
    expect(r, isA<Ok<void>>(), reason: '$r');

    final inC2 = await newPhotos(cora, c2, beforeC2);
    final inG3 = await newPhotos(cora, g3, beforeG3);
    expect(inC2, hasLength(2));
    expect(inG3, hasLength(2));
    expect(inC2.every((m) => m.forwarded), isTrue);
    final gC2 = inC2.map((m) => m.photoGroup).toSet();
    final gG3 = inG3.map((m) => m.photoGroup).toSet();
    expect(gC2, hasLength(1));
    expect(gG3, hasLength(1));
    expect(gC2.single, isNotNull);
    expect(gG3.single, isNotNull);
    expect(gC2.single, isNot(sourceGroup));
    expect(gG3.single, isNot(gC2.single));

    final beforePlain = await ids(cora, c2);
    final plain = await ctl.forwardTo(source.last, conversationIds: [c2]);
    expect(plain, isA<Ok<void>>(), reason: '$plain');
    final one = await newPhotos(cora, c2, beforePlain);
    expect(one, hasLength(1));
    expect(one.single.photoGroup, isNull);
  });

  test('controller: an upload the server refuses ends the album -- the error '
      'comes back and no pending bubble is left', () async {
    final before = await ids(beth, c1);
    final container = await reidInC1();
    // A type the attachments bucket does not allow: storage refuses it.
    final notAnImage = PickedImage(
      bytes: Uint8List.fromList(utf8.encode('not a photo')),
      contentType: 'text/html',
      extension: 'html',
    );

    final result = await container.read(messagesProvider.notifier).sendImages([
      _photo(),
      notAnImage,
      _photo(),
    ], body: 'half');

    expect(
      result,
      isA<Err<void>>(),
      reason: 'the bucket took a type it does not allow',
    );
    expect(
      container.read(messagesProvider).requireValue.where((m) => m.isPending),
      isEmpty,
    );
    final stored = await newPhotos(beth, c1, before);
    expect(stored, hasLength(1), reason: 'only the first photo is stored');
  });
}
