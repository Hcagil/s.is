import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../support/l10n.dart';

void main() {
  setUp(() => failureLanguage = 'en');
  tearDown(() => failureLanguage = 'en');

  test('tagProblem in Turkish', () {
    failureLanguage = 'tr';
    expect(tagProblem('ab'), l10nTr.failTagShort);
    expect(tagProblem('ab'), isNot(l10nEn.failTagShort));
  });

  test('offline failure in Turkish', () {
    failureLanguage = 'tr';
    final failure = readableFailure(const SocketException('x'));
    expect(failure.message, l10nTr.failOffline);
    expect(failure.message, isNot(l10nEn.failOffline));
  });

  test('localized failure in Turkish', () {
    failureLanguage = 'tr';
    final failure = NetworkFailure.localized((s) => s.failCanceled);
    expect(failure.message, l10nTr.failCanceled);
    expect(failure.message, isNot(l10nEn.failCanceled));
  });

  test('PinLimitFailure in Turkish', () {
    failureLanguage = 'tr';
    final failure = const PinLimitFailure();
    expect(failure.message, l10nTr.chatPinLimit);
    expect(failure.message, isNot(l10nEn.chatPinLimit));
  });

  test('empty display name in English', () {
    final msg = displayNameProblem('');
    expect(msg, l10nEn.failNameEmpty);
    expect(msg, 'Enter a name');
  });
}
