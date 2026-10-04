// MessagesController's newest-page open (0.30.14), from its contract:
// - the first read is the newest page without previews; one batched
//   attachmentPreviews call for the photo rows lacking one follows the first
//   paint; rows get their preview by id; a failure is silent; an answer for a
//   chat since left is dropped; known previews survive a rebuild.
// - loadOlder() pages through messagesAround(oldest shown), adding only
//   unseen rows not newer than the anchor; a page with fewer than
//   messagePageSize rows at or before the anchor ends paging; one load at a
//   time; olderLoadingProvider is true only during the call; an answer that
//   arrives after a rebuild or a jump is dropped.
// - jumpToAround resets the older-paging state.
// Against ChatFake, whose messages() answers the newest page without
// previews and whose messagesAround answers the real window (up to 50
// older, the anchor, up to 50 newer).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

final _t0 = DateTime.utc(2026, 1, 1);

bool _isPhoto(int i) => i % 10 == 3;

/// Photos at 3, 13, 23 ...; those at 3, 23, 43 ... have a stored preview,
/// those at 13, 33, 53 ... have none.
Uint8List? _previewOf(int i) =>
    i % 20 == 3 ? Uint8List.fromList([i % 256, 7]) : null;

List<Message> _history(String id, int n) => [
  for (var i = 0; i < n; i++)
    Message(
      id: '$id-$i',
      conversationId: id,
      senderId: i.isEven ? 'me' : 'bob',
      body: _isPhoto(i) ? '' : 'hay $i',
      createdAt: _t0.add(Duration(minutes: i)),
      attachmentPath: _isPhoto(i) ? '$id/p$i.png' : null,
      attachmentPreview: _isPhoto(i) ? _previewOf(i) : null,
    ),
];

/// Polls [done] until it holds, or fails after [timeout].
Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 3),
  String reason = '',
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  List<Message> rows() => c.read(messagesProvider).requireValue;
  List<String> shown() => rows().map((m) => m.id).toList();
  Message row(String id) => rows().firstWhere((m) => m.id == id);
  MessagesController messages() => c.read(messagesProvider.notifier);
  List<String> arounds() =>
      chat.calls.where((x) => x.startsWith('around:')).toList();

  Future<void> open(String id) async {
    c.read(openConversationProvider.notifier).open(id);
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
  }

  /// Lets the background work after an open (previews, verify) finish.
  Future<void> quiet() =>
      Future<void>.delayed(const Duration(milliseconds: 600));

  setUp(() {
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    chat.history['c1'] = _history('c1', 120);
    chat.history['c2'] = _history('c2', 30);
    c = ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(chat)],
    );
    c.listen(messagesProvider, (_, _) {});
    c.listen(olderLoadingProvider, (_, _) {});
  });

  tearDown(() => c.dispose());

  group('first read', () {
    test('the newest page only, oldest first, no previews yet', () async {
      chat.holdPreviews(); // previews never arrive in this test
      await open('c1');
      expect(shown(), [for (var i = 70; i < 120; i++) 'c1-$i']);
      expect(rows().every((m) => m.attachmentPreview == null), isTrue);
      expect(messages().hasOlder, isTrue, reason: 'a full page: maybe more');
    });

    test('a page shorter than messagePageSize: nothing older', () async {
      await open('c2');
      expect(shown(), hasLength(30));
      expect(messages().hasOlder, isFalse);
    });
  });

  group('previews after first paint', () {
    final photosInPage = [
      for (var i = 70; i < 120; i++)
        if (_isPhoto(i)) 'c1-$i',
    ];

    test('one batched call for the photo rows of the page, then each row '
        'carries its own preview by id', () async {
      await open('c1');
      await _until(() => chat.previewCalls.isNotEmpty, reason: 'no batch');
      expect(
        chat.previewCalls.first.toSet(),
        photosInPage.toSet(),
        reason: 'every photo row of the page, and only those, in one call',
      );
      expect(chat.previewCalls.first, hasLength(photosInPage.length));
      await _until(
        () => row('c1-83').attachmentPreview != null,
        reason: 'preview never applied',
      );
      for (var i = 70; i < 120; i++) {
        expect(
          row('c1-$i').attachmentPreview,
          _previewOf(i) == null ? isNull : equals(_previewOf(i)),
          reason: 'c1-$i must carry its own preview (or none)',
        );
      }
    });

    test('asked once per id per build, plus once after the verify re-read; '
        'never for a text row', () async {
      await open('c1');
      await quiet();
      expect(chat.previewCalls, isNotEmpty);
      expect(chat.previewCalls.length, lessThanOrEqualTo(2));
      final all = [for (final call in chat.previewCalls) ...call];
      expect(all.toSet().difference(photosInPage.toSet()), isEmpty);
      expect(
        all.toSet().length,
        all.length,
        reason: 'an id is asked once per build, even one with no preview',
      );
      // A live text message is no reason to ask again.
      final before = chat.previewCalls.length;
      chat.deliver(
        Message(
          id: 'c1-live',
          conversationId: 'c1',
          senderId: 'bob',
          body: 'hi',
          createdAt: _t0.add(const Duration(days: 1)),
        ),
      );
      await quiet();
      expect(chat.previewCalls.length, before);
    });

    test('a chat with no photo makes no preview request', () async {
      chat.history['c3'] = [
        for (var i = 0; i < 10; i++)
          Message(
            id: 'c3-$i',
            conversationId: 'c3',
            senderId: 'bob',
            body: 'text $i',
            createdAt: _t0.add(Duration(minutes: i)),
          ),
      ];
      await open('c3');
      await quiet();
      expect(
        chat.calls.where((x) => x.startsWith('previews:')),
        isEmpty,
        reason: 'nothing to ask: no round trip',
      );
    });

    test('a failed preview read is silent: no error, rows stay without a '
        'preview', () async {
      chat.previewsResult = const Err(NetworkFailure('offline'));
      await open('c1');
      await quiet();
      expect(chat.previewCalls, isNotEmpty);
      expect(c.read(messagesProvider).hasError, isFalse);
      expect(shown(), hasLength(messagePageSize));
      expect(rows().every((m) => m.attachmentPreview == null), isTrue);
    });

    test('an answer for a chat since left is dropped', () async {
      final held = chat.holdPreviews();
      await open('c1');
      await _until(() => chat.previewCalls.isNotEmpty, reason: 'no batch');
      await open('c2');
      held.complete();
      await quiet();
      expect(shown().every((id) => id.startsWith('c2-')), isTrue);
      expect(c.read(messagesProvider).hasError, isFalse);
    });

    test('a preview answer from a replaced build is dropped', () async {
      final stale = chat.holdPreviews();
      await open('c1');
      await _until(() => chat.previewCalls.isNotEmpty, reason: 'no batch');
      // The new build's own preview reads fail: its rows stay without one.
      chat.previewsResult = const Err(NetworkFailure('offline'));
      c.invalidate(messagesProvider);
      await c.read(messagesProvider.future);
      await quiet();
      final marker = Uint8List.fromList([9, 9, 9]);
      chat.previewsResult = Ok({'c1-83': marker});
      stale.complete();
      await quiet();
      expect(
        row('c1-83').attachmentPreview,
        isNull,
        reason: 'the replaced build\'s answer must not land',
      );
    });

    test('known previews carry over a rebuild: never back to null', () async {
      await open('c1');
      await _until(
        () => row('c1-83').attachmentPreview != null,
        reason: 'preview never applied',
      );
      await quiet();
      // From here on preview reads never answer.
      for (var i = 0; i < 5; i++) {
        chat.holdPreviews();
      }
      final seen = <Uint8List?>[];
      c.listen(messagesProvider, (_, next) {
        final list = next.value;
        if (list == null) return;
        for (final m in list) {
          if (m.id == 'c1-83') seen.add(m.attachmentPreview);
        }
      });
      c.invalidate(messagesProvider);
      await c.read(messagesProvider.future);
      await quiet();
      expect(row('c1-83').attachmentPreview, equals(_previewOf(83)));
      expect(seen, isNot(contains(isNull)), reason: 'no flicker back to null');
    });
  });

  group('loadOlder', () {
    test('pages through the whole chat: no gap, no duplicate, sorted, and '
        'stops at the oldest', () async {
      await open('c1');
      await quiet();

      await messages().loadOlder();
      expect(arounds(), ['around:c1:c1-70'], reason: 'oldest shown anchor');
      expect(shown(), [for (var i = 20; i < 120; i++) 'c1-$i']);
      expect(messages().hasOlder, isTrue);

      await messages().loadOlder();
      expect(arounds().last, 'around:c1:c1-20');
      expect(shown(), [for (var i = 0; i < 120; i++) 'c1-$i']);
      expect(
        messages().hasOlder,
        isFalse,
        reason: 'only 20 rows were older than c1-20: fewer than a page',
      );

      final asked = arounds().length;
      await messages().loadOlder();
      expect(arounds(), hasLength(asked), reason: 'nothing older: no read');
    });

    test('older rows carry their stored previews', () async {
      await open('c1');
      await quiet();
      await messages().loadOlder();
      await quiet();
      expect(row('c1-23').attachmentPreview, equals(_previewOf(23)));
      expect(row('c1-33').attachmentPreview, isNull);
    });

    test('a row newer than the anchor that the shown list lacks is not '
        'added', () async {
      await open('c1');
      await quiet();
      // A window holding a row newer than the anchor that is not shown.
      final stray = Message(
        id: 'c1-stray',
        conversationId: 'c1',
        senderId: 'bob',
        body: 'newer than the anchor',
        createdAt: _t0.add(const Duration(minutes: 90, seconds: 30)),
      );
      chat.messagesAroundResult = Ok([
        for (var i = 20; i <= 70; i++) chat.history['c1']![i],
        stray,
      ]);
      await messages().loadOlder();
      expect(shown(), isNot(contains('c1-stray')));
      expect(shown(), [for (var i = 20; i < 120; i++) 'c1-$i']);
    });

    test('one load at a time; olderLoadingProvider true only during the '
        'call', () async {
      await open('c1');
      await quiet();
      expect(c.read(olderLoadingProvider), isFalse);
      final held = chat.holdAround();
      final first = messages().loadOlder();
      await _until(() => arounds().isNotEmpty, reason: 'no read');
      expect(c.read(olderLoadingProvider), isTrue);
      await messages().loadOlder(); // in flight: a no-op
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(arounds(), hasLength(1));
      held.complete();
      await first;
      expect(c.read(olderLoadingProvider), isFalse);
      expect(shown(), hasLength(100));
    });

    test('a failed read is silent and the next scroll may try again', () async {
      await open('c1');
      await quiet();
      final before = shown();
      chat.messagesAroundResult = const Err(NetworkFailure('offline'));
      await messages().loadOlder();
      expect(shown(), before);
      expect(c.read(messagesProvider).hasError, isFalse);
      expect(c.read(olderLoadingProvider), isFalse);
      expect(messages().hasOlder, isTrue);
      chat.messagesAroundResult = null;
      await messages().loadOlder();
      expect(shown(), hasLength(100));
    });

    test('an empty chat: no read', () async {
      chat.history['c0'] = [];
      await open('c0');
      await messages().loadOlder();
      expect(arounds(), isEmpty);
    });

    test('an answer arriving after a rebuild is dropped', () async {
      await open('c1');
      await quiet();
      final held = chat.holdAround();
      final pending = messages().loadOlder();
      await _until(() => arounds().isNotEmpty, reason: 'no read');
      c.invalidate(messagesProvider);
      await c.read(messagesProvider.future);
      held.complete();
      await pending;
      await quiet();
      expect(shown(), [for (var i = 70; i < 120; i++) 'c1-$i']);
    });

    test('a vanished row in an older page is not added', () async {
      await open('c1');
      await quiet();
      final rows = [for (var i = 20; i <= 70; i++) chat.history['c1']![i]];
      final gone = rows[10]; // c1-30
      rows[10] = Message(
        id: gone.id,
        conversationId: gone.conversationId,
        senderId: gone.senderId,
        body: '',
        createdAt: gone.createdAt,
        deletion: MessageDeletion.vanished,
      );
      chat.messagesAroundResult = Ok(rows);
      await messages().loadOlder();
      expect(shown(), isNot(contains('c1-30')));
      expect(shown(), contains('c1-29'));
      expect(shown(), contains('c1-31'));
    });

    test(
      'after a rebuild dropped an answer, scrolling up pages again',
      () async {
        await open('c1');
        await quiet();
        final held = chat.holdAround();
        final pending = messages().loadOlder();
        await _until(() => arounds().isNotEmpty, reason: 'no read');
        c.invalidate(messagesProvider);
        await c.read(messagesProvider.future);
        held.complete();
        await pending;
        await quiet();
        await messages().loadOlder();
        expect(arounds(), hasLength(2), reason: 'not stuck "in flight"');
        expect(shown(), hasLength(100));
      },
    );

    test('the loader stays on while the current build\'s page is in flight, '
        'even when a replaced build\'s answer lands', () async {
      await open('c1');
      await quiet();
      final stale = chat.holdAround();
      final first = messages().loadOlder();
      await _until(() => arounds().isNotEmpty, reason: 'no read');
      c.invalidate(messagesProvider);
      await c.read(messagesProvider.future);
      await quiet();
      final current = chat.holdAround();
      final second = messages().loadOlder();
      await _until(() => arounds().length == 2, reason: 'no second read');
      expect(c.read(olderLoadingProvider), isTrue);
      stale.complete();
      await first;
      expect(
        c.read(olderLoadingProvider),
        isTrue,
        reason: 'a page is still in flight',
      );
      current.complete();
      await second;
      expect(c.read(olderLoadingProvider), isFalse);
    });

    test('an answer arriving after a jump is dropped', () async {
      await open('c1');
      await quiet();
      final held = chat.holdAround();
      final pending = messages().loadOlder();
      await _until(() => arounds().isNotEmpty, reason: 'no read');
      final anchor = chat.history['c1']![10];
      final jumped = await messages().jumpToAround(anchor);
      expect(jumped, isA<Ok<void>>());
      final window = shown();
      held.complete();
      await pending;
      await quiet();
      expect(shown(), window, reason: 'the old page must not land in it');
      expect(window, aroundRows(chat.history['c1']!, anchor).map((m) => m.id));
    });

    test('an answer arriving after the chat was left is dropped', () async {
      await open('c1');
      await quiet();
      final held = chat.holdAround();
      final pending = messages().loadOlder();
      await _until(() => arounds().isNotEmpty, reason: 'no read');
      await open('c2');
      held.complete();
      await pending;
      await quiet();
      expect(shown().every((id) => id.startsWith('c2-')), isTrue);
    });
  });

  group('jumpToAround', () {
    test('loads the window with previews and resets older paging', () async {
      await open('c1');
      await quiet();
      await messages().loadOlder();
      await messages().loadOlder();
      expect(messages().hasOlder, isFalse, reason: 'fixture: paged to end');

      final anchor = chat.history['c1']![80];
      await messages().jumpToAround(anchor);
      await quiet();
      expect(shown(), [for (var i = 30; i <= 119; i++) 'c1-$i']);
      expect(row('c1-43').attachmentPreview, equals(_previewOf(43)));
      expect(messages().hasOlder, isTrue, reason: 'paging state reset');

      final asked = arounds().length;
      await messages().loadOlder();
      expect(arounds(), hasLength(asked + 1));
      expect(arounds().last, 'around:c1:c1-30');
      expect(shown().first, 'c1-0');
    });
  });
}
