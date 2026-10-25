import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/open_queue.dart';

void main() {
  group('OpenQueue', () {
    /// Helper to pump the event loop a few times.
    Future<void> pump() async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('1. One job at a time', () async {
      final queue = OpenQueue();
      final logs = <String>[];
      var running = 0;
      var maxConcurrent = 0;

      Future<void> job(int i, Completer<void> completer) async {
        running++;
        if (running > maxConcurrent) maxConcurrent = running;
        logs.add('start:$i');
        await completer.future;
        logs.add('end:$i');
        running--;
      }

      final c0 = Completer<void>();
      final c1 = Completer<void>();
      final c2 = Completer<void>();

      final f0 = queue.run(() => job(0, c0));
      final f1 = queue.run(() => job(1, c1));
      final f2 = queue.run(() => job(2, c2));

      await pump();
      expect(logs, ['start:0']);
      expect(maxConcurrent, 1);

      c0.complete();
      await pump();
      await f0;
      expect(logs, ['start:0', 'end:0', 'start:1']);
      expect(maxConcurrent, 1);

      c1.complete();
      await pump();
      await f1;
      expect(logs, ['start:0', 'end:0', 'start:1', 'end:1', 'start:2']);
      expect(maxConcurrent, 1);

      c2.complete();
      await pump();
      await f2;
      expect(logs, [
        'start:0',
        'end:0',
        'start:1',
        'end:1',
        'start:2',
        'end:2',
      ]);
      expect(maxConcurrent, 1);
    });

    test('2. FIFO among normal jobs', () async {
      final queue = OpenQueue();
      final order = <String>[];

      Future<void> job(String name, Completer<void> completer) async {
        order.add('start:$name');
        await completer.future;
        order.add('end:$name');
      }

      final cA = Completer<void>();
      final cB = Completer<void>();
      final cC = Completer<void>();

      final fA = queue.run(() => job('A', cA));
      final fB = queue.run(() => job('B', cB));
      final fC = queue.run(() => job('C', cC));

      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:A']);

      cA.complete();
      await fA;
      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:A', 'end:A', 'start:B']);

      cB.complete();
      await fB;
      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:A', 'end:A', 'start:B', 'end:B', 'start:C']);

      cC.complete();
      await fC;
      expect(order, [
        'start:A',
        'end:A',
        'start:B',
        'end:B',
        'start:C',
        'end:C',
      ]);
    });

    test('3. Low after normal', () async {
      final queue = OpenQueue();
      final order = <String>[];

      Future<void> job(
        String name,
        Completer<void> completer, {
        bool low = false,
      }) async {
        order.add('start:$name');
        await completer.future;
        order.add('end:$name');
      }

      final cA = Completer<void>();
      final cL = Completer<void>();
      final cN = Completer<void>();

      final fA = queue.run(() => job('A', cA));
      final fL = queue.run(() => job('L', cL), low: true);
      final fN = queue.run(() => job('N', cN));

      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:A']);

      cA.complete();
      await fA;
      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:A', 'end:A', 'start:N']);

      cN.complete();
      await fN;
      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:A', 'end:A', 'start:N', 'end:N', 'start:L']);

      cL.complete();
      await fL;
      expect(order, [
        'start:A',
        'end:A',
        'start:N',
        'end:N',
        'start:L',
        'end:L',
      ]);
    });

    test('4. Running low job is not interrupted', () async {
      final queue = OpenQueue();
      final order = <String>[];

      Future<void> job(
        String name,
        Completer<void> completer, {
        bool low = false,
      }) async {
        order.add('start:$name');
        await completer.future;
        order.add('end:$name');
      }

      final cL = Completer<void>();
      final cN = Completer<void>();

      final fL = queue.run(() => job('L', cL), low: true);
      final fN = queue.run(() => job('N', cN));

      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:L']);

      cL.complete();
      await fL;
      await Future<void>.delayed(Duration.zero);
      expect(order, ['start:L', 'end:L', 'start:N']);

      cN.complete();
      await fN;
      expect(order, ['start:L', 'end:L', 'start:N', 'end:N']);
    });

    test('5. Low jobs keep their order and wait for a normal job queued '
        'after them', () async {
      final queue = OpenQueue();
      final order = <String>[];
      final hold = Completer<void>();
      final fs = [
        queue.run(() async {
          order.add('N1');
          await hold.future;
        }),
        queue.run(() async => order.add('L1'), low: true),
        queue.run(() async => order.add('L2'), low: true),
        queue.run(() async => order.add('N2')),
      ];
      await pump();
      expect(order, ['N1']);
      hold.complete();
      await Future.wait(fs);
      expect(order, ['N1', 'N2', 'L1', 'L2']);
    });

    test('9. A waiting low job is passed by at most one normal job', () async {
      final queue = OpenQueue();
      final order = <String>[];
      final hold = Completer<void>();
      final fs = [
        queue.run(() async {
          order.add('N0');
          await hold.future;
        }),
        queue.run(() async => order.add('L'), low: true),
        for (var i = 1; i <= 5; i++) queue.run(() async => order.add('N$i')),
      ];
      await pump();
      hold.complete();
      await Future.wait(fs);
      final passed = order.indexOf('L') - 1; // normal jobs run between N0 and L
      expect(passed, lessThanOrEqualTo(1), reason: '$order');
      expect(order.where((o) => o.startsWith('N')), hasLength(6));
    });

    test('6. A failed job does not stop the queue', () async {
      final queue = OpenQueue();

      final f1 = queue.run(() async => throw StateError('x'));
      final f2 = queue.run(() async => 2);

      await expectLater(f1, throwsA(isA<StateError>()));
      final result = await f2;
      expect(result, 2);
    });

    test('7. Result reaches caller', () async {
      final queue = OpenQueue();

      final r1 = await queue.run(() async => 42);
      expect(r1, 42);

      final r2 = await queue.run(() async => 'low', low: true);
      expect(r2, 'low');
    });

    test(
      '8. After the queue drains, a new job starts immediately again',
      () async {
        final queue = OpenQueue();

        final c1 = Completer<void>();
        final f1 = queue.run(() async {
          await c1.future;
          return 1;
        });

        await Future<void>.delayed(Duration.zero);
        expect(f1, completes);

        c1.complete();
        final r1 = await f1;
        expect(r1, 1);

        final r2 = await queue.run(() async => 2);
        expect(r2, 2);
      },
    );
  });
}
