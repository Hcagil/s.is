// PeerKeyCache, written from its interface and contract (draft by
// test_writer, corrected by qa), never from the implementation.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/peer_key_cache.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';

import '../../support/opener_fakes.dart' show keysOf;

void main() {
  late DateTime clock;
  late List<String> calls;
  late Result<ClaimedKeys?> Function(String) answer;

  setUp(() {
    clock = DateTime(2026, 1, 1);
    calls = [];
    answer = (id) => Ok(keysOf(id));
  });

  Future<Result<ClaimedKeys?>> fetch(String id) async {
    calls.add(id);
    return answer(id);
  }

  PeerKeyCache make() => PeerKeyCache(fetch, now: () => clock);

  test('two gets within ttl: one fetch, same keys', () async {
    final cache = make();
    final a = await cache.get('bob');
    final b = await cache.get('bob');
    expect(calls, ['bob']);
    expect((a as Ok<ClaimedKeys?>).value!.identityKey, 'IK-bob');
    expect((b as Ok<ClaimedKeys?>).value!.identityKey, 'IK-bob');
  });

  test('at 4m59s still cached; after 5 min fetched again', () async {
    final cache = make();
    await cache.get('bob');
    clock = clock.add(const Duration(minutes: 4, seconds: 59));
    await cache.get('bob');
    expect(calls, hasLength(1));
    clock = clock.add(const Duration(seconds: 2));
    await cache.get('bob');
    expect(calls, hasLength(2));
  });

  test('fresh: true always fetches, also right after a cached get', () async {
    final cache = make();
    await cache.get('bob');
    await cache.get('bob', fresh: true);
    await cache.get('bob', fresh: true);
    expect(calls, hasLength(3));
  });

  test('a fresh result is kept for later normal gets', () async {
    final cache = make();
    await cache.get('bob', fresh: true);
    await cache.get('bob');
    expect(calls, hasLength(1));
  });

  test('peers are cached separately', () async {
    final cache = make();
    await cache.get('bob');
    await cache.get('carol');
    await cache.get('bob');
    await cache.get('carol');
    expect(calls, ['bob', 'carol']);
  });

  test('Err is returned and never kept', () async {
    answer = (_) => const Err(NetworkFailure('off', retryable: true));
    final cache = make();
    final r = await cache.get('bob');
    expect(((r as Err).failure as NetworkFailure).message, 'off');
    await cache.get('bob');
    expect(calls, hasLength(2));
  });

  test('Ok(null) is returned and never kept', () async {
    answer = (_) => const Ok(null);
    final cache = make();
    final r = await cache.get('bob');
    expect((r as Ok<ClaimedKeys?>).value, isNull);
    await cache.get('bob');
    expect(calls, hasLength(2));
  });

  test('drop forgets only that peer', () async {
    final cache = make();
    await cache.get('bob');
    await cache.get('carol');
    cache.drop('bob');
    await cache.get('bob');
    await cache.get('carol');
    expect(calls, ['bob', 'carol', 'bob']);
  });

  void timesOutAt(Duration limit, PeerKeyCache Function() build) {
    fakeAsync((async) {
      final cache = build();
      Result<ClaimedKeys?>? got;
      cache.get('bob').then((r) => got = r);
      async.elapse(limit - const Duration(milliseconds: 100));
      expect(got, isNull, reason: 'still waiting before the limit');
      async.elapse(const Duration(milliseconds: 200));
      expect(got, isA<Err<ClaimedKeys?>>());
      final f = (got! as Err).failure;
      expect(f, isA<NetworkFailure>());
      expect((f as NetworkFailure).retryable, isTrue);
    });
  }

  test('a fetch that never answers ends as retryable Err at 8 s', () {
    timesOutAt(
      const Duration(seconds: 8),
      () => PeerKeyCache(
        (_) => Completer<Result<ClaimedKeys?>>().future,
        now: () => clock,
      ),
    );
  });

  test('custom timeout 2 s', () {
    timesOutAt(
      const Duration(seconds: 2),
      () => PeerKeyCache(
        (_) => Completer<Result<ClaimedKeys?>>().future,
        timeout: const Duration(seconds: 2),
        now: () => clock,
      ),
    );
  });

  test('after a timeout the next get fetches again', () {
    fakeAsync((async) {
      var n = 0;
      final cache = PeerKeyCache((_) {
        n++;
        return Completer<Result<ClaimedKeys?>>().future;
      }, now: () => clock);
      cache.get('bob');
      async.elapse(const Duration(seconds: 9));
      cache.get('bob');
      async.flushMicrotasks();
      expect(n, 2);
    });
  });

  test('a fetch that throws TimeoutException gives retryable Err', () async {
    final cache = PeerKeyCache(
      (_) async => throw TimeoutException('t'),
      now: () => clock,
    );
    final r = await cache.get('bob');
    expect(((r as Err).failure as NetworkFailure).retryable, isTrue);
  });
}
