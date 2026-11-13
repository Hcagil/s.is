import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/sign_out_wipe.dart';

void main() {
  test('the third delete runs when the first and second throw', () async {
    final log = <String>[];
    Future<void> a() async {
      log.add('a');
      throw StateError('first');
    }

    Future<void> b() async {
      log.add('b');
      throw StateError('second');
    }

    Future<void> c() async {
      log.add('c');
    }

    await expectLater(wipeSignOutKeys([a, b, c]), throwsA(isA<StateError>()));
    expect(log, ['a', 'b', 'c']);
  });

  test('the first error is rethrown, not the second', () async {
    final log = <String>[];
    Future<void> a() async {
      log.add('a');
      throw StateError('first');
    }

    Future<void> b() async {
      log.add('b');
      throw StateError('second');
    }

    Future<void> c() async {
      log.add('c');
    }

    await expectLater(
      wipeSignOutKeys([a, b, c]),
      throwsA(predicate((e) => e is StateError && e.message == 'first')),
    );
    expect(log, ['a', 'b', 'c']);
  });

  test('completes normally when none throw and all three run', () async {
    final log = <String>[];
    Future<void> a() async {
      log.add('a');
    }

    Future<void> b() async {
      log.add('b');
    }

    Future<void> c() async {
      log.add('c');
    }

    await wipeSignOutKeys([a, b, c]);
    expect(log, ['a', 'b', 'c']);
  });
}
