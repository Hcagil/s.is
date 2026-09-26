// Every plain PostgREST read in data/ retries at most once, so a dead server
// is reported in about a second instead of about seven (PostgREST's default
// is three retries with 1 s + 2 s + 4 s of backoff). A cheap source scan, like
// the own-design guard: every `.from(...)` chain that reads with `.select(`
// -- and does not write (insert/update/upsert/delete) -- must go through
// `.retriedOnce()`. Storage's `.storage.from(...)` is not PostgREST and is
// skipped. The timing itself is proven against a dead host in
// test/integration/quick_retry_integration_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [source] without `//` comments (doc comments included).
String code(String source) => source
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

final _from = RegExp(r'\.from\(');
final _write = RegExp(r'\.(insert|update|upsert|delete)\(');

/// Every `.from(...)` statement in [source] that is a PostgREST read, with
/// its 1-based line: from `.from(` to the statement's `;`.
List<(int, String)> reads(String source) => [
  for (final m in _from.allMatches(source))
    if (!RegExp(r'storage\s*$').hasMatch(source.substring(0, m.start)))
      if (source.substring(m.start, _end(source, m.start)) case final chain
          when chain.contains('.select(') && !_write.hasMatch(chain))
        ('\n'.allMatches(source.substring(0, m.start)).length + 1, chain),
];

int _end(String s, int from) {
  final i = s.indexOf(';', from);
  return i < 0 ? s.length : i;
}

void main() {
  final files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) {
            final p = f.path.replaceAll(r'\', '/');
            return p.contains('/data/');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final all = [
    for (final f in files)
      for (final (line, chain) in reads(code(f.readAsStringSync())))
        (where: '${f.path}:$line', chain: chain),
  ];

  test('there are PostgREST reads to check', () {
    // Not vacuous: the chat, profile, notification-settings, auth and update
    // repositories all read tables.
    expect(all.length, greaterThanOrEqualTo(8), reason: '$all');
    expect(
      {for (final r in all) r.where.split(':').first}.length,
      greaterThanOrEqualTo(4),
      reason: 'reads found in too few repositories: $all',
    );
  });

  test('every PostgREST read in data/ goes through .retriedOnce()', () {
    final missing = [
      for (final r in all)
        if (!r.chain.contains('.retriedOnce()'))
          '${r.where}: ${r.chain.replaceAll(RegExp(r'\s+'), ' ').trim()}',
    ];
    expect(missing, isEmpty, reason: 'a read left on the ~7 s default retry');
  });

  test('the scan sees a read without the helper (self-check)', () {
    const bad = '''
      final rows = await _client.from('messages').select('id').eq('a', b);
      final ok = await _client
          .from('profiles')
          .select()
          .retriedOnce();
      await _client.from('x').insert({'a': 1}).select();
      await _client.storage.from('photos').download(p);
    ''';
    final found = reads(bad);
    expect(found.length, 2, reason: '$found');
    expect(found.where((r) => !r.$2.contains('.retriedOnce()')).single.$1, 1);
  });
}
