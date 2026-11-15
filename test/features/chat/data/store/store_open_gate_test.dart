// written from the contract; real SQLite3MC files in a temp dir;
// store 1 is held inside its open by a drift QueryInterceptor (the only fake);
// the store on another file is the bound, so no sleep decides the result.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'store_harness.dart';

class _Hold extends QueryInterceptor {
  _Hold(this.name, this.events);
  final String name;
  final List<String> events;
  final entered = Completer<void>();
  Completer<void>? release; // when set, the FIRST ensureOpen waits for it
  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    if (!entered.isCompleted) {
      events.add('open-$name');
      entered.complete();
      final r = release;
      if (r != null) await r.future;
    }
    return super.ensureOpen(executor, user);
  }
}

void main() {
  late StoreHarness h;
  late String key;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
  });

  DriftMessageStore storeAt(File f, {String owner = 'owner-1', String? k}) {
    final s = DriftMessageStore(
      ownerId: owner,
      file: () async => f,
      key: () async => k ?? key,
      deleteKey: () async => h.deleteKeyCalls++,
    );
    addTearDown(s.close);
    return s;
  }

  group('opens on one file wait for each other', () {
    test('store 2 on the same new file does not start its open while store 1 is inside its open; a store on another file does not wait', () async {
      final f = File(p.join(h.dir.path, 'gate.sqlite'));
      final other = File(p.join(h.dir.path, 'other.sqlite'));
      final events = <String>[];

      final i1 = _Hold('1', events)..release = Completer<void>();

      final s1 = DriftMessageStore(
        ownerId: 'owner-1',
        file: () async => f,
        key: () async => key,
        deleteKey: () async => h.deleteKeyCalls++,
        interceptor: i1,
      );
      addTearDown(s1.close);
      // registered after s1.close, so it runs first and frees store 1
      addTearDown(() {
        if (!i1.release!.isCompleted) i1.release!.complete();
      });
      final save1 = s1.upsertAll([msg('one')]);

      await i1.entered.future.timeout(const Duration(seconds: 10));

      final file2 = Completer<void>();
      final s2 = DriftMessageStore(
        ownerId: 'owner-1',
        file: () async {
          if (!file2.isCompleted) file2.complete();
          return f;
        },
        key: () async => key,
        deleteKey: () async => h.deleteKeyCalls++,
        interceptor: _Hold('2', events),
      );
      addTearDown(s2.close);
      final save2 = s2
          .upsertAll([msg('two', t: 1)])
          .then((_) => events.add('saved2'));

      await file2.future.timeout(const Duration(seconds: 10));

      final s3 = storeAt(other);
      await s3.upsertAll([msg('three')]).timeout(const Duration(seconds: 10));
      expect(ids(await s3.newest('c1')), [
        'three',
      ], reason: 'a store on another file does not wait');

      expect(
        events,
        isNot(contains('open-2')),
        reason:
            'store 2 began its open while store 1 was still inside its own: $events',
      );
      expect(
        events,
        isNot(contains('saved2')),
        reason: 'store 2 saved while store 1 was still opening: $events',
      );

      i1.release!.complete();
      await Future.wait([save1, save2]).timeout(const Duration(seconds: 20));

      expect(events, containsAllInOrder(['open-1', 'open-2', 'saved2']));
      expect(ids(await storeAt(f).newest('c1')), [
        'one',
        'two',
      ], reason: 'both saves kept');
      expect(h.deleteKeyCalls, 0, reason: 'deleteKey never called');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
