// Drafted by test_writer from the contract; reviewed by qa-lead.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/crypto/domain/key_engine.dart';

void main() {
  group('KeyEngineException', () {
    test('no args: toString() equals exactly "KeyEngineException"', () {
      final exception = KeyEngineException();
      expect(exception.cause, isNull);
      expect(exception.causeStackTrace, isNull);
      expect(exception.toString(), equals('KeyEngineException'));
    });

    test('with cause: StateError', () {
      final cause = StateError('Content hash on Dart side');
      final exception = KeyEngineException(cause: cause);
      expect(exception.cause, same(cause));
      expect(exception.causeStackTrace, isNull);
      expect(
        exception.toString(),
        equals('KeyEngineException: Bad state: Content hash on Dart side'),
      );
      expect(exception.toString(), contains('Content hash on Dart side'));
    });

    test('fields keep what was passed', () {
      final cause = 'boom';
      final stack = StackTrace.current;
      final exception = KeyEngineException(
        cause: cause,
        causeStackTrace: stack,
      );
      expect(exception.cause, same(cause));
      expect(exception.causeStackTrace, same(stack));
    });
  });
}
