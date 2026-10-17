@Tags(['speed'])
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../features/chat/data/store/store_harness.dart';
import '../support/fakes.dart';

/// Time from messagesProvider build to the stored first frame (store.newest
/// 50 + mapping) on a REAL encrypted store holding 100,000 messages over 50
/// chats, with the server read held open so the frame can only come from the
/// store. Cold: a new store instance (first query opens the file). Warm: the
/// same instance, another chat. Asserts every frame < 100 ms. Run:
///   flutter test --run-skipped --tags speed test/speed/stored_first_frame_bench_test.dart
const _total = 100000;
const _chats = 50;

void main() {
  test('stored first frame, 100k messages over 50 chats', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final seed = h.open(owner: 'me', key: key);
    const batch = 2000;
    for (var start = 0; start < _total; start += batch) {
      await seed.upsertAll([
        for (var i = start; i < start + batch; i++)
          Message(
            id: 'm$i',
            conversationId: 'c${i % _chats}',
            senderId: 'u${i % 7}',
            body: 'message number $i',
            createdAt: at(i),
          ),
      ]);
    }

    _say('seeded ${_total ~/ 1000}k');

    // The server holds the same chat: its newest page is the stored newest 50.
    List<Message> page(String id) {
      final k = int.parse(id.substring(1));
      return [
        for (var i = _total - _chats * 50 + k; i < _total; i += _chats)
          Message(
            id: 'm$i',
            conversationId: id,
            senderId: 'u${i % 7}',
            body: 'message number $i',
            createdAt: at(i),
          ),
      ];
    }

    Future<int> frame(ProviderContainer c, ChatFake chat, String id) async {
      chat.history[id] = page(id);
      chat.holdMessages();
      final first = Completer<List<Message>>();
      final sub = c.listen(messagesProvider, (_, next) {
        final v = next.value;
        if (v != null && v.isNotEmpty && !first.isCompleted) first.complete(v);
      });
      final w = Stopwatch()..start();
      c.read(openConversationProvider.notifier).open(id);
      final rows = await first.future.timeout(const Duration(seconds: 10));
      final us = w.elapsedMicroseconds;
      expect(rows, hasLength(50));
      expect(rows.last.id, 'm${_total - _chats + int.parse(id.substring(1))}');
      chat.releaseMessages();
      await c.read(messagesProvider.future);
      sub.close();
      return us;
    }

    ProviderContainer app(ChatFake chat) => ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        messageStoreProvider.overrideWithValue(h.open(owner: 'me', key: key)),
      ],
    );

    final cold = <int>[];
    final warm = <int>[];
    for (var run = 0; run < 3; run++) {
      final chat = ChatFake();
      final c = app(chat);
      cold.add(await frame(c, chat, 'c${run * 3}'));
      warm.add(await frame(c, chat, 'c${run * 3 + 1}'));
      warm.add(await frame(c, chat, 'c${run * 3 + 2}'));
    }
    String ms(List<int> us) =>
        us.map((u) => (u / 1000).toStringAsFixed(1)).join(' / ');
    _say('cold open (new store instance): ${ms(cold)} ms');
    _say('warm open (instance already open): ${ms(warm)} ms');
    final rw = Stopwatch()..start();
    await seed.reconcilePage('c49', const [], reachedStart: true);
    _say(
      'reconcile of an empty first page over 2,000 stored rows: '
      '${rw.elapsedMilliseconds} ms',
    );
    for (final us in [...cold, ...warm]) {
      expect(us, lessThan(100000), reason: 'stored first frame < 100 ms');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

// ignore: avoid_print
void _say(String s) => print('SPEED | stored first frame | $s');
