// test/features/admin_panels/application/admin_drafts_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/domain/admin_draft_store.dart';

class _Store implements AdminDraftStore {
  Map<String, String> saved = {};
  int loads = 0, saves = 0, clears = 0;

  @override
  Future<Map<String, String>> load() async {
    loads++;
    await Future<void>.delayed(Duration.zero);
    return Map.of(saved);
  }

  @override
  Future<void> save(Map<String, String> m) async {
    saves++;
    await Future<void>.delayed(Duration.zero);
    saved = Map.of(m);
  }

  @override
  Future<void> clear() async {
    clears++;
    await Future<void>.delayed(Duration.zero);
    saved = {};
  }
}

Future<void> pastDebounce() =>
    Future.delayed(const Duration(milliseconds: 650));

void main() {
  late _Store s;
  late AdminDrafts d;

  setUp(() {
    s = _Store();
    d = AdminDrafts(s);
  });

  tearDown(() {
    d.dispose();
  });

  test('1 construct does nothing', () async {
    expect(s.loads, 0);
    final r1 = await d.read('k');
    expect(r1, '');
    expect(s.loads, 1);
    final r2 = await d.read('k');
    expect(r2, '');
    expect(s.loads, 1);
  });

  test('2 restores', () async {
    s.saved = {'k': 'old'};
    final r = await d.read('k');
    expect(r, 'old');
  });

  test('3 debounce', () async {
    await d.write('k', 'hi');
    await Future.delayed(const Duration(milliseconds: 100));
    expect(s.saves, 0);
    await pastDebounce();
    expect(s.saves, 1);
    expect(s.saved, {'k': 'hi'});
  });

  test('4 several writes inside debounce', () async {
    await d.write('k', 'ab');
    await Future.delayed(const Duration(milliseconds: 50));
    await d.write('k', 'abc');
    await pastDebounce();
    expect(s.saves, 1);
    expect(s.saved, {'k': 'abc'});
  });

  test('5 flush saves now', () async {
    await d.write('k', 'hi');
    await d.flush();
    expect(s.saved, {'k': 'hi'});
    expect(s.saves, 1);
    await pastDebounce();
    expect(s.saves, 1);
  });

  test('6 cap', () async {
    final long = 'a' * 9000;
    await d.write('k', long);
    final r = await d.read('k');
    expect(r.length, adminDraftMax);
    await d.flush();
    expect(s.saved['k']!.length, adminDraftMax);
    final exact = 'b' * adminDraftMax;
    await d.write('k', exact);
    await d.flush();
    expect(s.saved['k']!.length, adminDraftMax);
    final over = 'c' * (adminDraftMax + 1);
    await d.write('k', over);
    await d.flush();
    expect(s.saved['k']!.length, adminDraftMax);
  });

  test('7 blank removes', () async {
    await d.write('k', 'hi');
    await d.write('k', '   \n');
    await d.flush();
    expect(s.saved.isEmpty, true);
    final r = await d.read('k');
    expect(r, '');
  });

  test('8 remove', () async {
    await d.write('k', 'hi');
    await d.flush();
    await d.write('j', 'x');
    await d.remove('k');
    expect(s.saved, {'j': 'x'});
  });

  test('9 prune', () async {
    await d.write('q:a', '1');
    await d.write('q:b', '2');
    await d.write('talk:x', '3');
    await d.write('talk:new', '4');
    await d.prune('q:', {'a'});
    await d.prune('talk:', {'new'});
    await d.flush();
    expect(s.saved.keys.toSet(), {'q:a', 'talk:new'});
  });

  test('10 forget', () async {
    await d.write('k', 'hi');
    await d.forget();
    expect(s.saved, {'k': 'hi'});
    final r = await d.read('k');
    expect(r, 'hi');
    expect(s.loads, 2);
  });

  test('11 wipe', () async {
    await d.write('k', 'hi');
    await d.flush();
    await d.wipe();
    expect(s.clears, 1);
    expect(s.saved.isEmpty, true);
    final r = await d.read('k');
    expect(r, '');
    // test that a pending write before wipe does not save later
    final s2 = _Store();
    final d2 = AdminDrafts(s2);
    await d2.write('k', 'z');
    await d2.wipe();
    await pastDebounce();
    expect(s2.saves, 0);
    final r2 = await d2.read('k');
    expect(r2, '');
    d2.dispose();
  });

  test('12 dispose cancels pending timer', () async {
    await d.write('k', 'hi');
    d.dispose();
    await pastDebounce();
    expect(s.saves, 0);
  });

  test('13 helpers', () async {
    expect(adminDraftMax, 8192);
    expect(adminDraftDebounce, const Duration(milliseconds: 500));
    expect(adminTalkDraftKey(null), 'talk:new');
    expect(adminTalkDraftKey('conv'), 'talk:conv');
    expect(adminQuestionDraftKey('id'), 'q:id');
  });
}
