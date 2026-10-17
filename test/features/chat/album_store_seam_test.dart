// Seam: photo albums (MessagesController.sendImages, buildTimeline) <-> the
// REAL encrypted on-phone store (DriftMessageStore on a temp file, spied)
// <-> a server fake that is never instant and can drop an upload. Written
// from the contract (main's photo albums meet the on-phone store), never the
// code:
// - photoGroup survives a store write and read;
// - 2+ stored photos with one photoGroup and one sender, read back on a
//   stored-first open (before the server answers), fold into one album;
// - after a successful album send every photo row, with its group, is stored;
// - no pending bubble (id pending-...) is ever written to the store;
// - after a failed album send the unsent bubbles are not in the store.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/timeline.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/store_spy.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

/// The server: each upload takes time, answers with the stored row carrying
/// the group it was sent with, and a chosen upload drops like a connection.
class _Server extends ChatFake {
  _Server() : super(latency: const Duration(milliseconds: 3), self: 'u1');

  /// 1-based upload numbers that fail.
  final failing = <int>{};

  /// When set, every upload waits for it (pending bubbles stay up).
  Completer<void>? hold;
  int uploads = 0;

  /// When true each landed row also comes back over Realtime a moment
  /// later, as an insert does to every live subscriber (the sender too).
  /// When false the echo is missed (subscription not ready or dropped).
  bool echo = false;
  final groupsSent = <String?>[];

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    final n = ++uploads;
    groupsSent.add(image.photoGroup);
    await Future<void>.delayed(latency);
    if (hold case final g?) await g.future;
    if (failing.contains(n)) {
      return const Err(NetworkFailure('connection dropped', retryable: true));
    }
    final row = Message(
      id: 'srv-$n',
      conversationId: conversationId,
      senderId: 'u1',
      body: body,
      createdAt: at(100 + n),
      attachmentPath: '$conversationId/srv-$n.jpg',
      photoGroup: image.photoGroup,
    );
    store(row.attachmentPath!, image.bytes);
    if (echo) {
      Future<void>.delayed(latency, () => deliver(row));
    } else {
      (history[conversationId] ??= []).add(row);
    }
    return Ok(row);
  }
}

PickedImage _shot(int i) => PickedImage(
  bytes: Uint8List.fromList([...photoPng, i]),
  contentType: 'image/jpeg',
  extension: 'jpg',
  preview: Uint8List.fromList([...pngBytes, i]),
);

List<PickedImage> _shots(int n) => [for (var i = 0; i < n; i++) _shot(i)];

Message _photo(String id, {required String sender, String? group, int t = 0}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: sender,
      body: '',
      createdAt: at(t),
      attachmentPath: 'c1/$id.jpg',
      photoGroup: group,
    );

bool _pendingLike(Message m) => m.id.startsWith('pending-') || m.sending;

void main() {
  late StoreHarness h;
  late String key;
  late DriftMessageStore real;
  var realClosed = false;
  late SpyStore store;
  late _Server chat;

  Future<ProviderContainer> app(SpyStore s, {bool open = true}) async {
    chat.history['c1'] ??= [];
    chat.conversationsResult = const Ok([Conversation(id: 'c1', title: 'B')]);
    for (final m in chat.history['c1']!) {
      if (m.attachmentPath case final p?) chat.store(p);
    }
    final c = await settled(
      ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          messageStoreProvider.overrideWithValue(s),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      ),
    );
    c.listen(messagesProvider, (_, _) {});
    if (open) {
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      // The open's background reads (its second, verifying read included)
      // finish first, so nothing a send stores can come from them.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return c;
  }

  Future<List<Message>> stored() => real.newest('c1', limit: 500);

  /// Every id the controller ever asked the store to write.
  List<String> writtenIds() => [
    for (final call in store.calls)
      if (call.startsWith('upsert:'))
        ...call.substring('upsert:'.length).split(',').where((s) => s != ''),
  ];

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 300));

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    real = h.open(owner: 'u1', key: key);
    realClosed = false;
    addTearDown(() => realClosed ? null : real.close());
    store = SpyStore(real);
    chat = _Server();
  });

  test('photoGroup survives a write and a read of the real store', () async {
    await real.upsertAll([
      _photo('a', sender: 'u2', group: 'g1'),
      _photo('b', sender: 'u2'),
    ]);
    final back = {for (final m in await stored()) m.id: m};
    expect(back['a']!.photoGroup, 'g1');
    expect(back['b']!.photoGroup, isNull);
  });

  test('stored photos sharing a group and a sender fold into one album on a '
      'stored-first open, before the server answers', () async {
    await real.upsertAll([
      msg('t0', t: 0, sender: 'u2', body: 'look'),
      _photo('a', sender: 'u2', group: 'g1', t: 1),
      _photo('b', sender: 'u2', group: 'g1', t: 2),
      _photo('c', sender: 'u2', group: 'g1', t: 3),
      _photo('lone', sender: 'u2', t: 4),
    ]);
    chat.history['c1'] = [];
    chat.holdMessages();
    final c = await app(store, open: false);
    c.read(openConversationProvider.notifier).open('c1');
    await eventually(
      () => (c.read(messagesProvider).value?.length ?? 0) == 5,
      reason: 'stored rows before the server answers',
    );
    expect(chat.calls.where((x) => x.startsWith('messages:c1')), isNotEmpty);

    final entries = buildTimeline(
      c.read(messagesProvider).value!,
      const [],
    ).whereType<MessageEntry>().toList();
    expect(entries.map((e) => e.message.id), ['t0', 'a', 'lone']);
    expect(ids(entries[1].album), ['a', 'b', 'c']);
    expect(entries[2].album, isEmpty);

    chat.releaseMessages();
    await c.read(messagesProvider.future);
    await settle();
  });

  for (final echo in [false, true]) {
    test('after a successful album send every photo row is stored with its '
        'group, and a reopen from the store folds them into one album '
        '(Realtime echo ${echo ? 'arrives' : 'missed'})', () async {
      chat.echo = echo;
      final c = await app(store);
      final result = await c
          .read(messagesProvider.notifier)
          .sendImages(_shots(3), body: 'beach');
      expect(result, isA<Ok<void>>(), reason: '$result');
      final group = chat.groupsSent.first;
      expect(group, isNotNull);
      expect(chat.groupsSent.toSet(), {group});

      try {
        await eventually(() async => (await stored()).length == 3);
      } on StateError {
        fail(
          'the three sent photos never reached the store: stored '
          '${ids(await stored())}, store writes ${store.calls}, shown '
          '${ids(c.read(messagesProvider).value ?? const [])}',
        );
      }
      await settle();
      final rows = await stored();
      expect(ids(rows), ['srv-1', 'srv-2', 'srv-3']);
      expect(rows.map((m) => m.photoGroup).toSet(), {group});
      expect(rows.map((m) => m.attachmentPath), [
        'c1/srv-1.jpg',
        'c1/srv-2.jpg',
        'c1/srv-3.jpg',
      ]);
      expect(rows.where(_pendingLike), isEmpty);

      // A fresh app over the same file, server held: the album comes back whole.
      c.dispose();
      await real.close();
      realClosed = true;
      final again = h.open(owner: 'u1', key: key);
      addTearDown(again.close);
      chat.holdMessages();
      final c2 = await app(SpyStore(again), open: false);
      c2.read(openConversationProvider.notifier).open('c1');
      await eventually(
        () => (c2.read(messagesProvider).value?.length ?? 0) == 3,
        reason: 'stored-first open after the send',
      );
      final entries = buildTimeline(
        c2.read(messagesProvider).value!,
        const [],
      ).whereType<MessageEntry>().toList();
      expect(entries, hasLength(1));
      expect(ids(entries.single.album), ['srv-1', 'srv-2', 'srv-3']);
      chat.releaseMessages();
      await c2.read(messagesProvider.future);
      await settle();
    });
  }

  for (final echo in [false, true]) {
    test(
      'no pending bubble is written to the store, while the uploads are '
      'in flight or after them (Realtime echo ${echo ? 'arrives' : 'missed'})',
      () async {
        chat.echo = echo;
        final c = await app(store);
        chat.hold = Completer<void>();
        final sending = c.read(messagesProvider.notifier).sendImages(_shots(3));

        await eventually(
          () =>
              (c.read(messagesProvider).value ?? const <Message>[])
                  .where((m) => m.isPending)
                  .length ==
              3,
          reason: 'three pending bubbles up',
        );
        await settle();
        expect(writtenIds().where((id) => id.startsWith('pending-')), isEmpty);
        expect((await stored()).where(_pendingLike), isEmpty);

        chat.hold!.complete();
        expect(await sending, isA<Ok<void>>());
        await settle();
        await settle();
        expect(
          writtenIds().where((id) => id.startsWith('pending-')),
          isEmpty,
          reason: 'store writes: ${store.calls}',
        );
        expect((await stored()).where(_pendingLike), isEmpty);
      },
    );
  }

  test('a single photo send (no album) is stored with no Realtime echo, '
      'as every landed send is', () async {
    final c = await app(store);
    expect(
      await c.read(messagesProvider.notifier).sendImages([_shot(0)]),
      isA<Ok<void>>(),
    );
    await settle();
    expect(ids(await stored()), ['srv-1'], reason: 'writes ${store.calls}');
  });

  for (final echo in [false, true]) {
    test(
      'a failed album send leaves only the sent photo in the store, none of '
      'the unsent bubbles (Realtime echo ${echo ? 'arrives' : 'missed'})',
      () async {
        chat.echo = echo;
        final c = await app(store);
        chat.failing.add(2);
        final result = await c
            .read(messagesProvider.notifier)
            .sendImages(_shots(3));
        expect(result, isA<Err<void>>(), reason: '$result');
        await settle();

        final rows = await stored();
        expect(
          rows.where(_pendingLike),
          isEmpty,
          reason: 'writes ${store.calls}',
        );
        expect(writtenIds().where((id) => id.startsWith('pending-')), isEmpty);
        expect(
          ids(rows).where((id) => id != 'srv-1'),
          isEmpty,
          reason: 'only the one photo that landed may be stored',
        );
        // The photo that did land (criterion 3, checked last so the above is
        // judged on its own).
        expect(ids(rows), ['srv-1'], reason: 'store writes: ${store.calls}');
        expect(rows.single.photoGroup, chat.groupsSent.first);
      },
    );
  }

  test('an album whose first upload fails stores nothing', () async {
    final c = await app(store);
    chat.failing.add(1);
    final result = await c
        .read(messagesProvider.notifier)
        .sendImages(_shots(3));
    expect(result, isA<Err<void>>(), reason: '$result');
    await settle();

    expect(await stored(), isEmpty, reason: 'store writes: ${store.calls}');
    expect(writtenIds(), isEmpty);
  });
}
