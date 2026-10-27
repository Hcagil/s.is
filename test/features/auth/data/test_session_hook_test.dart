import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/data/test_session_hook.dart';

void main() {
  group('consumeTestSession', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tsh_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test(
      'enabled:false with file present returns false and file remains',
      () async {
        final file = File('${tmp.path}/test_session.json');
        file.writeAsStringSync('{"refresh_token":"x"}');

        int signInCalls = 0;
        final result = await consumeTestSession(
          signIn: (_) async => signInCalls++,
          root: () async => tmp,
          enabled: false,
        );

        expect(result, false);
        expect(signInCalls, 0);
        expect(file.existsSync(), true);
      },
    );

    test('enabled:false with root throwing StateError returns false and root not called', () async {
      bool rootCalled = false;
      int signInCalls = 0;

      final result = await consumeTestSession(
        signIn: (_) async => signInCalls++,
        root: () async {
          rootCalled = true;
          throw StateError('boom');
        },
        enabled: false,
      );

      expect(result, false);
      expect(signInCalls, 0);
      expect(rootCalled, false);
    });

    test('enabled:true with no file returns false', () async {
      int signInCalls = 0;
      final result = await consumeTestSession(
        signIn: (_) async => signInCalls++,
        root: () async => tmp,
        enabled: true,
      );

      expect(result, false);
      expect(signInCalls, 0);
    });

    test('enabled:true with file present consumes session and removes file before signIn', () async {
      final file = File('${tmp.path}/test_session.json');
      file.writeAsStringSync('{"refresh_token":"x"}');

      int signInCalls = 0;
      String? tokenPassed;
      bool fileExistsBeforeSignIn = true;

      final result = await consumeTestSession(
        signIn: (String token) async {
          signInCalls++;
          tokenPassed = token;
          fileExistsBeforeSignIn = file.existsSync();
        },
        root: () async => tmp,
        enabled: true,
      );

      expect(result, true);
      expect(signInCalls, 1);
      expect(tokenPassed, 'x');
      expect(fileExistsBeforeSignIn, false);
      expect(file.existsSync(), false);
    });

    test('malformed JSON returns false and deletes file', () async {
      final file = File('${tmp.path}/test_session.json');
      file.writeAsStringSync('{not json');

      int signInCalls = 0;
      final result = await consumeTestSession(
        signIn: (_) async => signInCalls++,
        root: () async => tmp,
        enabled: true,
      );

      expect(result, false);
      expect(signInCalls, 0);
      expect(file.existsSync(), false);
    });

    final malformedBodies = [
      '{not json',
      '{}',
      '{"refresh_token":""}',
      '{"refresh_token":42}',
      '{"refresh_token":null}',
      '[]',
      '"x"',
    ];

    for (final body in malformedBodies) {
      test('malformed JSON body $body returns false', () async {
        final file = File('${tmp.path}/test_session.json');
        file.writeAsStringSync(body);

        int signInCalls = 0;
        final result = await consumeTestSession(
          signIn: (_) async => signInCalls++,
          root: () async => tmp,
          enabled: true,
        );

        expect(result, false);
        expect(signInCalls, 0);
        expect(file.existsSync(), false);
      });
    }

    test('signIn throws Exception and token is not logged', () async {
      final file = File('${tmp.path}/test_session.json');
      file.writeAsStringSync('{"refresh_token":"secret-tok-123"}');

      final captured = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          captured.add(message ?? '');
      addTearDown(() {
        debugPrint = originalDebugPrint;
      });

      final result = await runZoned(
        () async {
          return await consumeTestSession(
            signIn: (String token) async {
              expect(token, 'secret-tok-123');
              throw Exception('boom-tok');
            },
            root: () async => tmp,
            enabled: true,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            captured.add(line);
            return parent.print(zone, line);
          },
        ),
      );

      expect(result, false);
      expect(file.existsSync(), false);
      for (final line in captured) {
        expect(
          line.contains('secret-tok-123'),
          false,
          reason: 'Token should not be logged',
        );
      }
    });

    test('single use: first call consumes, second call does not', () async {
      final file = File('${tmp.path}/test_session.json');
      file.writeAsStringSync('{"refresh_token":"x"}');

      int signInCalls = 0;

      final first = await consumeTestSession(
        signIn: (_) async => signInCalls++,
        root: () async => tmp,
        enabled: true,
      );
      final second = await consumeTestSession(
        signIn: (_) async => signInCalls++,
        root: () async => tmp,
        enabled: true,
      );

      expect(first, true);
      expect(second, false);
      expect(signInCalls, 1);
    });
  });
}
