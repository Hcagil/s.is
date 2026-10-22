// storeWrite (Private Chats 4b Group J), from its contract: a fire-and-forget
// store write whose failure never escapes as an unhandled async error, and is
// logged by its type only (the error text can hold message text).
// First draft by the local test_writer; reviewed and reworked.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/store_write.dart';
import 'package:sis/features/chat/domain/message_store.dart'
    show StoreWriteException;

/// Runs [body] in its own error zone (every future made inside it, as a
/// store call would be), lets the event loop turn, and returns what escaped
/// as an uncaught error, plus every printed line.
Future<(List<Object>, List<String>)> watch(Future<void> Function() body) async {
  final errors = <Object>[];
  final printed = <String>[];
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      await body();
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      done.complete();
    },
    (e, _) => errors.add(e),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => printed.add(line),
    ),
  );
  await done.future.timeout(const Duration(seconds: 5));
  return (errors, printed);
}

void main() {
  for (final (name, Object error) in [
    ('StoreWriteException', const StoreWriteException()),
    ('an Exception holding row text', Exception('row text: meet at 6')),
    ('a StateError', StateError('bad state')),
  ]) {
    test('a failing write ($name) never escapes', () async {
      final (errors, _) = await watch(
        () async => storeWrite(Future<void>.error(error)),
      );
      expect(errors, isEmpty);
    });
  }

  test('a write that fails later, after storeWrite returned, never '
      'escapes', () async {
    final (errors, _) = await watch(() async {
      final write = Completer<void>();
      storeWrite(write.future);
      await Future<void>.delayed(Duration.zero);
      write.completeError(const StoreWriteException());
    });
    expect(errors, isEmpty);
  });

  test('returns at once, before the write completes; a write that works '
      'leaves nothing behind', () async {
    final (errors, _) = await watch(() async {
      final write = Completer<void>();
      storeWrite(write.future);
      expect(write.isCompleted, isFalse);
      write.complete();
    });
    expect(errors, isEmpty);
  });

  test('the error text is never printed', () async {
    final (errors, printed) = await watch(
      () async => storeWrite(Future<void>.error(Exception('secret body 42'))),
    );
    expect(errors, isEmpty);
    expect(printed.where((l) => l.contains('secret body 42')), isEmpty);
  });
}
