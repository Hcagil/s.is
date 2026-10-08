// MessagesController.sendImages, written from its contract: one message per
// image, in list order, through the existing sendImage path; the caption on
// the first image only; stop at the first Err and return it unchanged, the
// rest not sent; Ok(null) when all are sent or there is nothing to send.
// Against the shared fake repository, which refuses what the real upload
// refuses (an empty image) and answers each call a little late.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

PickedImage shot(int i) => PickedImage(
  bytes: Uint8List.fromList([...photoPng, i]),
  contentType: 'image/jpeg',
  extension: 'jpg',
  preview: pngBytes,
);

/// What the upload refuses: nothing in it.
final empty = PickedImage(
  bytes: Uint8List(0),
  contentType: 'image/jpeg',
  extension: 'jpg',
);

Future<ProviderContainer> scope(ChatFake chat, {bool open = true}) async {
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  if (open) {
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
  }
  return c;
}

List<Uint8List> sentBytes(ChatFake chat) => [
  for (final s in chat.sentImages) s.image.bytes,
];

void main() {
  test('sends one message per image, in order, the caption on the first '
      'only, and appends them in that order', () async {
    final chat = ChatFake(latency: const Duration(milliseconds: 3));
    final c = await scope(chat);

    final result = await c.read(messagesProvider.notifier).sendImages([
      shot(1),
      shot(2),
      shot(3),
    ], body: 'beach');

    expect(result, isA<Ok<void>>());
    expect(sentBytes(chat), [shot(1).bytes, shot(2).bytes, shot(3).bytes]);
    expect([for (final s in chat.sentImages) s.body], ['beach', '', '']);
    expect(chat.sentImages.map((s) => s.conversationId).toSet(), {'c1'});
    final shown = c.read(messagesProvider).requireValue;
    expect(
      [
        for (final m in shown)
          if (m.attachmentPath != null) m.body,
      ],
      ['beach', '', ''],
      reason: 'each sent photo is in the conversation, in order',
    );
  });

  test('no caption: every image is sent with an empty body', () async {
    final chat = ChatFake();
    final c = await scope(chat);

    await c.read(messagesProvider.notifier).sendImages([shot(1), shot(2)]);

    expect([for (final s in chat.sentImages) s.body], ['', '']);
  });

  test('stops at the first Err and returns it; later images are not '
      'sent', () async {
    final chat = ChatFake();
    final c = await scope(chat);

    final result = await c.read(messagesProvider.notifier).sendImages([
      shot(1),
      empty,
      shot(3),
      shot(4),
    ], body: 'x');

    expect(result, isA<Err<void>>());
    expect((result as Err<void>).failure.message, 'the image is empty');
    expect(sentBytes(chat), [
      shot(1).bytes,
      empty.bytes,
    ], reason: 'nothing after the refused image may be attempted');
    final shown = c.read(messagesProvider).requireValue;
    expect(
      shown.where((m) => m.attachmentPath != null),
      hasLength(1),
      reason: 'the photo sent before the failure stays sent',
    );
  });

  test('a failure on the very first image: nothing else is tried', () async {
    final chat = ChatFake();
    final c = await scope(chat);

    final result = await c.read(messagesProvider.notifier).sendImages([
      empty,
      shot(2),
    ]);

    expect(result, isA<Err<void>>());
    expect(sentBytes(chat), [empty.bytes]);
  });

  test('an empty list sends nothing and is Ok(null)', () async {
    final chat = ChatFake();
    final c = await scope(chat);

    final result = await c
        .read(messagesProvider.notifier)
        .sendImages(const [], body: 'never sent');

    expect(result, isA<Ok<void>>());
    expect(chat.sentImages, isEmpty);
  });

  test('the repository\'s failure passes through unchanged', () async {
    final failure = NetworkFailure('the upload failed ${DateTime.now()}');
    final chat = ChatFake()..sendImageResult = Err(failure);
    final c = await scope(chat);

    final result = await c.read(messagesProvider.notifier).sendImages([
      shot(1),
      shot(2),
    ]);

    expect((result as Err<void>).failure, same(failure));
    expect(chat.sentImages, hasLength(1));
  });

  test('no open conversation: a DeniedFailure, nothing sent', () async {
    final chat = ChatFake();
    final c = await scope(chat, open: false);

    final result = await c.read(messagesProvider.notifier).sendImages([
      shot(1),
    ], body: 'x');

    expect((result as Err<void>).failure, isA<DeniedFailure>());
    expect(chat.sentImages, isEmpty);
  });
}
