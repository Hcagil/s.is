// Photo albums in MessagesController, from the contract (feat/photo-albums):
//
// sendImages(images, {body})
// - chunks of 10; a chunk of 2+ shares one fresh group; a chunk of 1 has none;
// - every pending bubble of a chunk is shown before its first upload starts,
//   each with the chunk's group; the caption is on photo 0 only;
// - no open conversation and some images: Err(DeniedFailure), nothing sent;
//   no images: Ok(null), nothing touched;
// - on the first Err, the chunk's remaining pending bubbles go and later
//   chunks are never shown; uploads keep the picking order.
// sendImage({chosen, shown}): with [shown] it adds no bubble of its own.
// forward / forwardTo with album: one repository call per photo per target,
// each target its own NEW group; otherwise ONE call, all targets, no group.
//
// The fake is a server: every call takes time, an upload answers with the
// stored row carrying the group it was sent with (photo_group is stored), and
// a chosen upload can fail the way a dropped connection does.
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
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class AlbumServer extends ChatFake {
  AlbumServer() : super(latency: const Duration(milliseconds: 3), self: 'u1');

  ProviderContainer? container;

  /// The conversation's photo entries as they were when each upload began.
  final shownAtUpload = <List<Message>>[];

  /// 1-based upload numbers that fail.
  final failing = <int>{};
  int _uploads = 0;

  /// Every forward as the repository received it.
  final forwards = <({String id, String? group, List<String> to})>[];

  /// 1-based forward calls that fail.
  final failingForwards = <int>{};

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    shownAtUpload.add(photos(container!));
    final n = ++_uploads;
    final result = await super.sendImage(
      conversationId: conversationId,
      image: image,
      body: body,
      replyTo: replyTo,
    );
    if (failing.contains(n)) {
      return const Err(NetworkFailure('connection dropped', retryable: true));
    }
    return result;
  }

  @override
  Future<Result<void>> forward(Message message, List<String> conversationIds) {
    forwards.add((
      id: message.id,
      group: message.photoGroup,
      to: List.of(conversationIds),
    ));
    if (failingForwards.contains(forwards.length)) {
      return Future.value(const Err(NetworkFailure('offline')));
    }
    return super.forward(message, conversationIds);
  }
}

PickedImage shot(int i) => PickedImage(
  bytes: Uint8List.fromList([...photoPng, i]),
  contentType: 'image/jpeg',
  extension: 'jpg',
  preview: Uint8List.fromList([...pngBytes, i]),
);

List<PickedImage> shots(int n) => [for (var i = 0; i < n; i++) shot(i)];

/// The last byte tells which shot an upload carried.
int tag(Uint8List bytes) => bytes.last;

Message stored(String id, {String? group, int minute = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: me.userId,
  body: '',
  createdAt: DateTime(2026, 10, 1, 9, minute),
  attachmentPath: 'c1/$id.jpg',
  photoGroup: group,
);

Future<ProviderContainer> scope(
  AlbumServer chat, {
  bool open = true,
  List<Message> history = const [],
}) async {
  chat
    ..history['c1'] = [...history]
    ..conversationsResult = const Ok([
      Conversation(id: 'c1', title: 'Bob'),
      Conversation(id: 'c2', title: 'Work'),
      Conversation(id: 'c3', title: 'Home'),
    ]);
  for (final m in history) {
    if (m.attachmentPath case final p?) chat.store(p);
  }
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
  chat.container = c;
  c.listen(messagesProvider, (_, _) {});
  if (open) {
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
  }
  return c;
}

List<Message> photos(ProviderContainer c) => [
  for (final m in c.read(messagesProvider).value ?? const <Message>[])
    if (m.hasAttachment) m,
];

Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 30));

MessagesController ctl(ProviderContainer c) =>
    c.read(messagesProvider.notifier);

void main() {
  group('sendImages', () {
    test('three photos: all three pending bubbles, one shared group, the '
        'caption on photo 0 only, are shown before the first upload', () async {
      final chat = AlbumServer();
      final c = await scope(chat);

      final result = await ctl(c).sendImages(shots(3), body: 'beach');
      expect(result, isA<Ok<void>>(), reason: '$result');

      final first = chat.shownAtUpload.first;
      expect(first, hasLength(3), reason: 'not every bubble was up first');
      expect(first.every((m) => m.isPending), isTrue);
      final group = first.first.photoGroup;
      expect(group, isNotNull);
      expect(first.map((m) => m.photoGroup).toSet(), {group});
      expect(first.map((m) => m.body), ['beach', '', '']);
      expect(first.map((m) => tag(m.localImage!)), [0, 1, 2]);

      // what reached the repository: same group, caption once, picking order
      expect(chat.sentImages.map((s) => s.image.photoGroup).toSet(), {group});
      expect(chat.sentImages.map((s) => s.body), ['beach', '', '']);
      expect(chat.sentImages.map((s) => tag(s.image.bytes)), [0, 1, 2]);

      await flush();
      expect(photos(c), hasLength(3), reason: 'one entry per photo at the end');
      expect(photos(c).any((m) => m.isPending), isFalse);
      expect(photos(c).map((m) => m.photoGroup).toSet(), {group});
    });

    test('a single photo has no group', () async {
      final chat = AlbumServer();
      final c = await scope(chat);

      expect(await ctl(c).sendImages([shot(7)], body: 'one'), isA<Ok<void>>());

      expect(chat.shownAtUpload.single.single.photoGroup, isNull);
      expect(chat.shownAtUpload.single.single.body, 'one');
      expect(chat.sentImages.single.image.photoGroup, isNull);
      await flush();
      expect(photos(c).single.photoGroup, isNull);
      expect(photos(c).single.isPending, isFalse);
    });

    test('a single photo keeps the phone\'s bytes once stored', () async {
      final chat = AlbumServer();
      final c = await scope(chat);

      await ctl(c).sendImages([shot(7)]);
      await flush();

      expect(photos(c).single.isPending, isFalse);
      expect(photos(c).single.localImage, isNotNull);
    });

    test('twelve photos: a chunk of 10 then a chunk of 2, each its own group; '
        'the second chunk is not shown while the first uploads', () async {
      final chat = AlbumServer();
      final c = await scope(chat);

      expect(await ctl(c).sendImages(shots(12), body: 'trip'), isA<Ok<void>>());

      expect(chat.shownAtUpload.first, hasLength(10));
      final groups = chat.sentImages.map((s) => s.image.photoGroup).toList();
      expect(groups, hasLength(12));
      expect(groups.take(10).toSet(), hasLength(1));
      expect(groups.skip(10).toSet(), hasLength(1));
      expect(groups.first, isNotNull);
      expect(groups.last, isNotNull);
      expect(groups.first, isNot(groups.last));
      expect(chat.sentImages.map((s) => tag(s.image.bytes)), [
        for (var i = 0; i < 12; i++) i,
      ]);
      // the 11th upload starts with the second chunk's 2 bubbles up
      final atEleven = chat.shownAtUpload[10];
      expect(
        atEleven.where((m) => m.isPending).map((m) => m.photoGroup).toSet(),
        {groups.last},
      );
      expect(atEleven.where((m) => m.isPending), hasLength(2));
      expect(chat.sentImages.map((s) => s.body), [
        'trip',
        for (var i = 1; i < 12; i++) '',
      ], reason: 'the caption goes on the very first photo only');
    });

    test('eleven photos: the lone 11th has no group', () async {
      final chat = AlbumServer();
      final c = await scope(chat);

      expect(await ctl(c).sendImages(shots(11)), isA<Ok<void>>());

      final groups = chat.sentImages.map((s) => s.image.photoGroup).toList();
      expect(groups.take(10).toSet(), hasLength(1));
      expect(groups.first, isNotNull);
      expect(groups.last, isNull);
    });

    test('no open conversation: DeniedFailure and nothing sent', () async {
      final chat = AlbumServer();
      final c = await scope(chat, open: false);

      final result = await ctl(c).sendImages(shots(2));

      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(chat.sentImages, isEmpty);
      expect(photos(c), isEmpty);
    });

    test('no images: Ok and nothing touched, open or not', () async {
      for (final open in [true, false]) {
        final chat = AlbumServer();
        final c = await scope(chat, open: open);
        await c.read(messagesProvider.future);
        final before = c.read(messagesProvider);
        final calls = chat.calls.length;

        final result = await ctl(c).sendImages(const []);

        expect(result, isA<Ok<void>>(), reason: 'open: $open');
        expect(chat.calls.length, calls, reason: 'a server call was made');
        expect(
          identical(c.read(messagesProvider), before),
          isTrue,
          reason: 'state was replaced (open: $open)',
        );
      }
    });

    test('the 2nd upload fails: the error comes back, no pending bubble '
        'stays, and the next chunk is never shown nor sent', () async {
      final chat = AlbumServer()..failing.add(2);
      final c = await scope(chat);
      final states = <List<Message>>[];
      c.listen(messagesProvider, (_, next) {
        states.add([
          for (final m in next.value ?? const <Message>[])
            if (m.hasAttachment) m,
        ]);
      });

      final result = await ctl(c).sendImages(shots(13));
      await flush();

      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<NetworkFailure>());
      expect(photos(c).where((m) => m.isPending), isEmpty);
      expect(photos(c), hasLength(1), reason: 'only photo 0 was stored');
      expect(
        chat.sentImages.map((s) => tag(s.image.bytes)).where((t) => t >= 10),
        isEmpty,
        reason: 'the second chunk was uploaded',
      );
      expect(
        states
            .expand((s) => s)
            .where((m) => m.localImage != null && tag(m.localImage!) >= 10),
        isEmpty,
        reason: 'the second chunk was shown',
      );
    });
  });

  /// What a frame could show: the state as it stands once the synchronous
  /// work that changed it has finished (two writes in one turn are one frame).
  List<List<Message>> visibleStates(ProviderContainer c) {
    final seen = <List<Message>>[];
    c.listen(messagesProvider, (_, _) {
      scheduleMicrotask(() => seen.add(photos(c)));
    });
    return seen;
  }

  test('an album never shows two entries for one photo', () async {
    final chat = AlbumServer();
    final c = await scope(chat);
    final seen = visibleStates(c);

    expect(await ctl(c).sendImages(shots(3)), isA<Ok<void>>());
    await flush();

    for (final s in seen) {
      expect(
        s.length,
        lessThanOrEqualTo(3),
        reason:
            'a photo had two entries at once: '
            '${[for (final m in s) '${m.id}:${m.isPending}']}',
      );
    }
  });

  test('a sent album ends in picking order, each entry keeping the '
      'phone\'s bytes', () async {
    final chat = AlbumServer();
    final c = await scope(chat);

    expect(await ctl(c).sendImages(shots(3)), isA<Ok<void>>());
    await flush();

    expect(photos(c), hasLength(3));
    expect(photos(c).any((m) => m.isPending), isFalse);
    expect(
      photos(c).every((m) => m.localImage != null),
      isTrue,
      reason:
          'a stored entry lost the phone\'s bytes: '
          '${[for (final m in photos(c)) '${m.id}:${m.localImage != null}']}',
    );
    expect(photos(c).map((m) => tag(m.localImage!)), [0, 1, 2]);
  });

  group('sendImage', () {
    test('with shown it adds no bubble of its own', () async {
      final chat = AlbumServer();
      final c = await scope(chat);
      final image = shot(1);
      final shown = Message(
        id: randomMessageId(),
        conversationId: 'c1',
        senderId: me.userId,
        body: '',
        createdAt: DateTime.now(),
        localImage: image.bytes,
      );

      await ctl(c).sendImage(chosen: image, shown: shown);

      expect(
        chat.shownAtUpload.single,
        isEmpty,
        reason: 'sendImage put up a bubble of its own',
      );
    });

    test('without shown it shows its own bubble before uploading', () async {
      final chat = AlbumServer();
      final c = await scope(chat);

      await ctl(c).sendImage(chosen: shot(1), body: 'hi');

      expect(chat.shownAtUpload.single, hasLength(1));
      expect(chat.shownAtUpload.single.single.isPending, isTrue);
      expect(chat.shownAtUpload.single.single.body, 'hi');
    });
  });

  group('forward', () {
    final album = [
      stored('p1', group: 'g-src', minute: 1),
      stored('p2', group: 'g-src', minute: 2),
      stored('p3', group: 'g-src', minute: 3),
    ];

    void expectAlbumPerTarget(AlbumServer chat, List<String> targets) {
      expect(chat.forwards, hasLength(album.length * targets.length));
      expect(
        chat.forwards.every((f) => f.to.length == 1),
        isTrue,
        reason: 'one call per photo per target',
      );
      final byTarget = <String, List<({String id, String? group})>>{};
      for (final f in chat.forwards) {
        byTarget.putIfAbsent(f.to.single, () => []).add((
          id: f.id,
          group: f.group,
        ));
      }
      expect(byTarget.keys.toSet(), targets.toSet());
      final groups = <String?>{};
      for (final t in targets) {
        final calls = byTarget[t]!;
        expect(calls.map((x) => x.id).toSet(), {'p1', 'p2', 'p3'});
        final g = calls.map((x) => x.group).toSet();
        expect(g, hasLength(1), reason: '$t got more than one group');
        expect(g.single, isNotNull);
        expect(g.single, isNot('g-src'), reason: 'the source group was reused');
        groups.add(g.single);
      }
      expect(
        groups,
        hasLength(targets.length),
        reason: 'targets share a group',
      );
    }

    test('an album to two chats: each chat gets every photo under its own '
        'new group', () async {
      final chat = AlbumServer();
      final c = await scope(chat, history: album);

      final r = await ctl(c).forward(album[1], ['c2', 'c3'], album: true);

      expect(r, isA<Ok<void>>(), reason: '$r');
      expectAlbumPerTarget(chat, ['c2', 'c3']);
    });

    test('forwardTo with album does the same', () async {
      final chat = AlbumServer();
      final c = await scope(chat, history: album);

      final r = await ctl(c)
          .forwardTo(album[0], conversationIds: ['c2', 'c3'], album: true);

      expect(r, isA<Ok<void>>(), reason: '$r');
      expectAlbumPerTarget(chat, ['c2', 'c3']);
    });

    test('without album, a photo of an album is ONE call to all targets with '
        'no group', () async {
      final chat = AlbumServer();
      final c = await scope(chat, history: album);

      final r = await ctl(c).forward(album[1], ['c2', 'c3']);

      expect(r, isA<Ok<void>>(), reason: '$r');
      expect(chat.forwards.single.id, 'p2');
      expect(chat.forwards.single.to, ['c2', 'c3']);
      expect(chat.forwards.single.group, isNull);
    });

    test('forwardTo without album: ONE call, no group', () async {
      final chat = AlbumServer();
      final c = await scope(chat, history: album);

      final r = await ctl(c).forwardTo(album[2], conversationIds: ['c2', 'c3']);

      expect(r, isA<Ok<void>>(), reason: '$r');
      expect(chat.forwards.single.to, ['c2', 'c3']);
      expect(chat.forwards.single.group, isNull);
    });

    test('album asked but only one photo carries the group: ONE call, no '
        'group', () async {
      final chat = AlbumServer();
      final lone = stored('solo', group: 'g-lone', minute: 5);
      final c = await scope(chat, history: [lone]);

      final r = await ctl(c).forward(lone, ['c2', 'c3'], album: true);

      expect(r, isA<Ok<void>>(), reason: '$r');
      expect(chat.forwards.single.to, ['c2', 'c3']);
      expect(chat.forwards.single.group, isNull);
    });

    test('an album forward whose first copy fails returns the error, even '
        'if later copies would succeed', () async {
      final chat = AlbumServer()..failingForwards.add(1);
      final c = await scope(chat, history: album);

      final r = await ctl(c).forward(album[0], ['c2'], album: true);

      expect(r, isA<Err<void>>());
    });
  });
}
