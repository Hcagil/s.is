// The hand-off from a pending photo to the stored message, from the 0.30.11
// contract: the stored row -- whichever of the Realtime echo or the POST
// answer arrives first -- takes the pending bubble's place, so the
// conversation holds exactly one entry per photo at every moment, and that
// entry keeps the phone's own bytes (localImage) to the end. A failed upload
// leaves no entry behind; a late echo of an already-stored photo never
// claims another pending one, even when the captions are identical.
//
// The fake answers each upload only when the test says so, and the echo is
// delivered the way Realtime delivers it: to the live subscription, at a
// moment of the test's choosing, before or after the answer.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// Every upload stays in flight until the test answers it, each on its own:
/// two photos in the air at once can be answered in either order.
class _Uploads extends ChatFake {
  final pending =
      <({PickedImage image, String body, Completer<Result<Message>> answer})>[];

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    // An upload is never synchronous.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final answer = Completer<Result<Message>>();
    pending.add((image: image, body: body, answer: answer));
    return answer.future;
  }
}

PickedImage shot(int i) => PickedImage(
  bytes: Uint8List.fromList([...photoPng, i]),
  contentType: 'image/jpeg',
  extension: 'jpg',
  // Each photo's own tiny preview, as the real sheet makes one per photo.
  preview: Uint8List.fromList([...pngBytes, i]),
);

/// The row the server stores for [image]: what both the echo and the POST
/// answer carry.
Message stored(int n, PickedImage image, {String body = ''}) => Message(
  id: 'img-$n',
  conversationId: 'c1',
  senderId: me.userId,
  body: body,
  createdAt: DateTime.now(),
  attachmentPath: 'c1/$n.jpg',
  attachmentPreview: image.preview,
);

Future<ProviderContainer> scope(ChatFake chat) async {
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
  c.listen(messagesProvider, (_, _) {});
  c.read(openConversationProvider.notifier).open('c1');
  await c.read(messagesProvider.future);
  return c;
}

/// Lets the controller and the fake run their awaits.
Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 10));

/// Every photo entry in the conversation, pending or stored.
List<Message> photos(ProviderContainer c) => [
  for (final m in c.read(messagesProvider).requireValue)
    if (m.hasAttachment) m,
];

void main() {
  test('echo first: the echo takes the pending entry\'s place at once, '
      'keeping the phone\'s bytes; the answer then changes nothing', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final image = shot(1);
    final row = stored(1, image, body: 'beach');

    final sending = c
        .read(messagesProvider.notifier)
        .sendImage(body: 'beach', chosen: image);
    await flush();
    expect(photos(c), hasLength(1), reason: 'the pending bubble is shown');
    expect(photos(c).single.isPending, isTrue);
    expect(photos(c).single.localImage, image.bytes);

    chat.deliver(row);
    await flush();
    expect(photos(c), hasLength(1), reason: 'the echo made a second bubble');
    expect(photos(c).single.id, row.id, reason: 'the echo did not take over');
    expect(photos(c).single.attachmentPath, row.attachmentPath);
    expect(photos(c).single.localImage, image.bytes);
    expect(photos(c).single.isPending, isFalse);

    chat.pending.single.answer.complete(Ok(row));
    final result = await sending;
    await flush();
    expect((result! as Ok<Message>).value.id, row.id);
    expect(photos(c), hasLength(1), reason: 'the answer made a second bubble');
    expect(photos(c).single.id, row.id);
    expect(photos(c).single.localImage, image.bytes);
  });

  test('answer first: the answer takes the pending entry\'s place, keeping '
      'the phone\'s bytes; the late echo changes nothing', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final image = shot(1);
    final row = stored(1, image, body: 'beach');

    final sending = c
        .read(messagesProvider.notifier)
        .sendImage(body: 'beach', chosen: image);
    await flush();
    chat.pending.single.answer.complete(Ok(row));
    await sending;
    await flush();
    expect(photos(c), hasLength(1));
    expect(photos(c).single.id, row.id);
    expect(photos(c).single.localImage, image.bytes);
    expect(photos(c).single.isPending, isFalse);

    chat.deliver(row);
    await flush();
    expect(photos(c), hasLength(1), reason: 'the late echo was added twice');
    expect(photos(c).single.id, row.id);
    expect(
      photos(c).single.localImage,
      image.bytes,
      reason: 'the echo replaced the entry and dropped the phone\'s bytes',
    );
  });

  test('a failed upload: the failure passes through and the pending entry '
      'is gone', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final failure = NetworkFailure('the upload failed ${DateTime.now()}');

    final sending = c
        .read(messagesProvider.notifier)
        .sendImage(body: 'beach', chosen: shot(1));
    await flush();
    chat.pending.single.answer.complete(Err(failure));
    final result = await sending;
    await flush();

    expect((result! as Err<Message>).failure, same(failure));
    expect(
      photos(c),
      isEmpty,
      reason:
          'a failed upload leaves no pending photo behind, and nothing '
          'that looks sent',
    );
  });

  test('two photos back-to-back, each echo and answer in its own order: '
      'one entry each, each with its own bytes', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final a = shot(1), b = shot(2);
    final rowA = stored(1, a, body: 'one'), rowB = stored(2, b, body: 'two');
    final notifier = c.read(messagesProvider.notifier);

    final sendingA = notifier.sendImage(body: 'one', chosen: a);
    await flush();
    final sendingB = notifier.sendImage(body: 'two', chosen: b);
    await flush();
    expect(photos(c), hasLength(2));

    // B's echo first, then A's answer, then B's answer, then A's echo.
    chat.deliver(rowB);
    await flush();
    expect(photos(c), hasLength(2));
    chat.pending[0].answer.complete(Ok(rowA));
    await sendingA;
    await flush();
    expect(photos(c), hasLength(2));
    chat.pending[1].answer.complete(Ok(rowB));
    await sendingB;
    chat.deliver(rowA);
    await flush();

    expect(photos(c).map((m) => m.id), [rowA.id, rowB.id]);
    expect(photos(c)[0].localImage, a.bytes);
    expect(photos(c)[1].localImage, b.bytes);
  });

  test('identical captions: a late echo of the first photo never claims the '
      'second, still pending one', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final a = shot(1), b = shot(2);
    final rowA = stored(1, a, body: 'same');
    final notifier = c.read(messagesProvider.notifier);

    final sendingA = notifier.sendImage(body: 'same', chosen: a);
    await flush();
    chat.pending[0].answer.complete(Ok(rowA));
    await sendingA;
    unawaited(notifier.sendImage(body: 'same', chosen: b));
    await flush();

    chat.deliver(rowA);
    await flush();

    expect(photos(c), hasLength(2), reason: 'one entry per photo');
    expect(photos(c)[0].id, rowA.id);
    expect(photos(c)[0].localImage, a.bytes);
    expect(
      photos(c)[1].isPending,
      isTrue,
      reason: 'the second photo has not been stored yet',
    );
    expect(photos(c)[1].localImage, b.bytes);
  });

  test('identical captions, both in the air: whichever echo comes first, '
      'each photo ends as one entry with its own bytes', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final a = shot(1), b = shot(2);
    final rowA = stored(1, a, body: 'same'), rowB = stored(2, b, body: 'same');
    final notifier = c.read(messagesProvider.notifier);

    final sendingA = notifier.sendImage(body: 'same', chosen: a);
    await flush();
    final sendingB = notifier.sendImage(body: 'same', chosen: b);
    await flush();

    chat.deliver(rowB);
    await flush();
    expect(photos(c), hasLength(2));
    chat.pending[1].answer.complete(Ok(rowB));
    await sendingB;
    chat.deliver(rowA);
    await flush();
    expect(photos(c), hasLength(2));
    chat.pending[0].answer.complete(Ok(rowA));
    await sendingA;
    await flush();

    final byId = {for (final m in photos(c)) m.id: m};
    expect(byId.keys, unorderedEquals([rowA.id, rowB.id]));
    expect(byId[rowA.id]!.localImage, a.bytes, reason: 'photos swapped');
    expect(byId[rowB.id]!.localImage, b.bytes, reason: 'photos swapped');
  });

  test('the pending entry carries the picked photo\'s own preview', () async {
    final chat = _Uploads();
    final c = await scope(chat);
    final image = shot(7);

    unawaited(
      c.read(messagesProvider.notifier).sendImage(body: 'x', chosen: image),
    );
    await flush();

    expect(photos(c).single.isPending, isTrue);
    expect(
      photos(c).single.attachmentPreview,
      image.preview,
      reason:
          'without its preview the pending photo matches any echo with '
          'its caption',
    );
  });

  test(
    'only my own stored photo row claims a pending photo: someone else\'s '
    'photo, or my text, with the same caption and preview never does',
    () async {
      final chat = _Uploads();
      final c = await scope(chat);
      final image = shot(1);

      unawaited(
        c
            .read(messagesProvider.notifier)
            .sendImage(body: 'same', chosen: image),
      );
      await flush();

      // Another member's photo, identical caption and preview.
      chat.deliver(
        Message(
          id: 'theirs',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'same',
          createdAt: DateTime.now(),
          attachmentPath: 'c1/theirs.jpg',
          attachmentPreview: image.preview,
        ),
      );
      // My own text message with the same caption.
      chat.deliver(
        Message(
          id: 'my-text',
          conversationId: 'c1',
          senderId: me.userId,
          body: 'same',
          createdAt: DateTime.now(),
        ),
      );
      await flush();

      final all = c.read(messagesProvider).requireValue;
      final mine = all.where((m) => m.isPending).toList();
      expect(mine, hasLength(1), reason: 'the pending photo was claimed');
      expect(mine.single.localImage, image.bytes);
      final theirs = all.singleWhere((m) => m.id == 'theirs');
      expect(theirs.localImage, isNull, reason: 'their photo took my bytes');
      final text = all.singleWhere((m) => m.id == 'my-text');
      expect(
        text.localImage,
        isNull,
        reason: 'my text took the photo\'s place',
      );
      expect(mine.single.id, isNot('my-text'));
    },
  );
}
