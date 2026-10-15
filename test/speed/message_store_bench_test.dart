@Tags(['speed'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../features/chat/data/store/store_harness.dart';

/// Timing probe for the on-phone message store on a REAL encrypted file:
/// 100,000 messages over 50 chats. Prints `SPEED | ...` lines and asserts
/// that opening the store (also a cold reopen of a file just opened) stays
/// under 100 ms. Run:
///   flutter test --run-skipped --tags speed test/speed/message_store_bench_test.dart
const _total = 100000;
const _chats = 50;

const _words = [
  'merhaba',
  'akşam',
  'yarın',
  'görüşürüz',
  'tamam',
  'evet',
  'hayır',
  'İstanbul',
  'Ankara',
  'toplantı',
  'kahve',
  'çay',
  'fotoğraf',
  'bak',
  'hello',
  'see',
  'you',
  'tomorrow',
  'meeting',
  'coffee',
  'thanks',
  'okay',
  'where',
  'are',
  'what',
  'time',
  'bridge',
  'ferry',
  'güzel',
  'olmuş',
];

void main() {
  test('100k messages over 50 chats', () async {
    final h = await StoreHarness.create();
    final key = await h.newKey();
    final rnd = Random(7);
    String body() => [
      for (var w = 0; w < 3 + rnd.nextInt(10); w++)
        _words[rnd.nextInt(_words.length)],
    ].join(' ');

    final seed = h.open(owner: 'owner-1', key: key);
    final sw = Stopwatch()..start();
    const batch = 2000;
    for (var start = 0; start < _total; start += batch) {
      await seed.upsertAll([
        for (var i = start; i < start + batch; i++)
          Message(
            id: 'm$i',
            conversationId: 'c${i % _chats}',
            senderId: 'u${i % 7}',
            body: i == 4242 ? 'zanzibar rare word' : body(),
            createdAt: at(i),
          ),
      ]);
    }
    _say('seed ${_total ~/ 1000}k messages: ${sw.elapsedMilliseconds} ms');
    expect((await seed.newest('c0', limit: 1)).length, 1);

    Future<int> timeOpen() async {
      final s = h.open(owner: 'owner-1', key: key);
      final w = Stopwatch()..start();
      await s.cursor();
      return w.elapsedMilliseconds;
    }

    final open1 = await timeOpen();
    final open2 = await timeOpen();
    final open3 = await timeOpen();
    _say('open (first query on a new instance): $open1 / $open2 / $open3 ms');

    final s = h.open(owner: 'owner-1', key: key);
    await s.newest('c3');
    Future<List<int>> times(Future<Object?> Function() f, [int n = 20]) async {
      final out = <int>[];
      for (var i = 0; i < n; i++) {
        final w = Stopwatch()..start();
        await f();
        out.add(w.elapsedMicroseconds);
      }
      out.sort();
      return out;
    }

    String med(List<int> us) =>
        'median ${(us[us.length ~/ 2] / 1000).toStringAsFixed(2)} ms, '
        'max ${(us.last / 1000).toStringAsFixed(2)} ms';

    _say('newest(50): ${med(await times(() => s.newest('c3')))}');
    final common = await s.search('istanbul');
    _say(
      'search("istanbul") ${common.length} hits: '
      '${med(await times(() => s.search('istanbul'), 10))}',
    );
    expect(common, hasLength(100));
    final rare = await s.search('zanzib');
    expect(rare.map((m) => m.id), ['m4242']);
    _say(
      'search("zanzib") ${rare.length} hit: '
      '${med(await times(() => s.search('zanzib'), 10))}',
    );
    _say(
      'search("ferry", one chat): '
      '${med(await times(() => s.search('ferry', conversationId: 'c9'), 10))}',
    );

    // FTS index size: whole database, then again with the FTS table dropped.
    Future<int> bytes() => s.run<int>(-1, (db) async {
      await db.customStatement('VACUUM');
      final pc = await db.customSelect('PRAGMA page_count').getSingle();
      final ps = await db.customSelect('PRAGMA page_size').getSingle();
      return (pc.data.values.first as int) * (ps.data.values.first as int);
    });
    final withFts = await bytes();
    final fts = await s.run<List<String>>(const [], (db) async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND sql LIKE '%fts5%'",
          )
          .get();
      return [for (final r in rows) r.read<String>('name')];
    });
    expect(fts, isNotEmpty, reason: 'an FTS5 table exists');
    await s.run<void>(null, (db) async {
      for (final t in fts) {
        await db.customStatement('DROP TABLE "$t"');
      }
    });
    final withoutFts = await bytes();
    final per10k = (withFts - withoutFts) / (_total / 10000);
    _say(
      'database ${_mb(withFts)} (FTS tables $fts); without FTS '
      '${_mb(withoutFts)}; FTS index per 10,000 messages: ${_mb(per10k)}',
    );

    expect(open1, lessThan(100));
    expect(open2, lessThan(100));
    expect(open3, lessThan(100));
  }, timeout: const Timeout(Duration(minutes: 10)));
}

String _mb(num b) => '${(b / 1024 / 1024).toStringAsFixed(2)} MB';

// ignore: avoid_print
void _say(String s) => print('SPEED | message store | $s');
