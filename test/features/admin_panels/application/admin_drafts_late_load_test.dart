import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';
import 'package:sis/features/admin_panels/domain/admin_draft_store.dart';

/// Fake store that can gate load operations.
class _GateStore implements AdminDraftStore {
  Map<String, String> saved = {};
  bool hold = false;
  final List<Completer<void>> gates = [];

  @override
  Future<Map<String, String>> load() async {
    if (hold) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    await Future<void>.delayed(Duration.zero);
    return Map.of(saved);
  }

  @override
  Future<void> save(Map<String, String> drafts) async {
    await Future<void>.delayed(Duration.zero);
    saved = Map.of(drafts);
  }

  @override
  Future<void> clear() async {
    await Future<void>.delayed(Duration.zero);
    saved = {};
  }
}

void main() {
  late AdminDrafts d;
  late _GateStore store;

  setUp(() {
    store = _GateStore();
    d = AdminDrafts(store);
  });

  tearDown(() {
    d.dispose();
  });

  test(
    'remove while the first load is still running: the draft stays removed',
    () async {
      store.saved = {'k': 'hello'};
      store.hold = true;

      final r = d.read('k'); // start load but don't await
      final rm = d.remove('k'); // start remove (will wait for load)
      await pumpEventQueue(); // allow remove to start waiting

      // Release the gate to finish the load
      store.hold = false;
      for (final gate in store.gates) {
        gate.complete();
      }

      await r;
      await rm;
      await d.flush();
      await pumpEventQueue();

      expect(await d.read('k'), '');
      expect(store.saved.containsKey('k'), isFalse);
    },
  );

  test('remove whose load finishes after a lock and a new unlock: the sent draft does not come back', () async {
    store.saved = {'k': 'hello'};
    store.hold = true;

    final rm = d.remove('k'); // load #1 pending
    await pumpEventQueue(); // allow remove to start waiting

    await d.forget(); // panels locked while remove's load is pending

    final r2 = d.read('k'); // new unlock: load #2 pending
    await pumpEventQueue();

    expect(store.gates.length, greaterThanOrEqualTo(1));

    // Open gates one at a time, oldest first
    if (store.gates.isNotEmpty) {
      store.gates[0].complete();
      await pumpEventQueue();
      await rm;
    }

    store.hold = false;
    for (final gate in store.gates) {
      if (!gate.isCompleted) gate.complete();
    }

    await r2;
    await d.flush();
    await pumpEventQueue();

    expect(
      await d.read('k'),
      '',
      reason: 'a sent draft came back after lock and unlock',
    );
    expect(
      store.saved.containsKey('k'),
      isFalse,
      reason: 'sent draft still saved on the phone',
    );
  });
}
