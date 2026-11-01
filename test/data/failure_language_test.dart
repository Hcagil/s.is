import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The three network sentences and the sign-in sentences, pinned as literals
/// in both languages; `failureLanguage` is reset so it never leaks.
void main() {
  setUp(() => failureLanguage = 'en');
  tearDown(() => failureLanguage = 'en');

  group('readableFailure', () {
    test('offline failure (en)', () {
      final e = const SocketException('Failed host lookup: nope');
      expect(
        readableFailure(e).message,
        'No connection. Check your internet and try again.',
      );
    });

    test('server failure (en)', () {
      final e = PostgrestException(message: 'x');
      expect(
        readableFailure(e).message,
        'Something went wrong on our side. Try again.',
      );
    });

    test('generic failure (en)', () {
      final e = StateError('boom');
      expect(readableFailure(e).message, 'Something went wrong. Try again.');
    });

    test('offline failure (tr)', () {
      failureLanguage = 'tr';
      final e = const SocketException('Failed host lookup: nope');
      expect(
        readableFailure(e).message,
        'Bağlantı yok. İnternetinizi kontrol edip tekrar deneyin.',
      );
    });

    test('server failure (tr)', () {
      failureLanguage = 'tr';
      final e = PostgrestException(message: 'x');
      expect(
        readableFailure(e).message,
        'Bizden kaynaklı bir sorun oluştu. Tekrar deneyin.',
      );
    });

    test('generic failure (tr)', () {
      failureLanguage = 'tr';
      final e = StateError('boom');
      expect(readableFailure(e).message, 'Bir şeyler ters gitti. Tekrar deneyin.');
    });
  });

  group('sign-in sentences', () {
    test('en', () {
      expect(signInFailedMessage, 'Could not sign in. Try again.');
      expect(signInCanceledMessage, 'Sign-in canceled.');
    });
    test('tr', () {
      failureLanguage = 'tr';
      expect(signInFailedMessage, 'Oturum açılamadı. Tekrar deneyin.');
      expect(signInCanceledMessage, 'Oturum açma iptal edildi.');
    });
  });

  group('failureText', () {
    test('returns English text when language is en', () {
      failureLanguage = 'en';
      expect(failureText('a', 'b'), 'a');
    });

    test('returns Turkish text when language is tr', () {
      failureLanguage = 'tr';
      expect(failureText('a', 'b'), 'b');
    });
  });
}
