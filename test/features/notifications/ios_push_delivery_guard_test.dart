// This test guards the iPhone notification extension's Swift sources.
// Written from the contract.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _dir = 'ios/NotificationService';
const _reader = '$_dir/PushDeliveryReader.swift';
const _call = '$_dir/PushDeliveryCall.swift';
const _core = '$_dir/PushDelivery.swift';
const _peek = '$_dir/PushPeek.swift';

String _read(String p) => File(p).readAsStringSync();

/// The source without // line comments, so a comment never satisfies or breaks a check.
String _code(String p) => _read(p)
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

void main() {
  test('the reader reads only the delivery item, in an access group', () {
    final c = _code(_reader);
    expect(c, contains('"sis.push.delivery"'));
    // the crypto group, found the way the rest of the extension finds it
    expect(c, contains('PeekKeychain.cryptoGroup()'));
    expect('PeekKeychain.value('.allMatches(c).length, 1, reason: 'one item');
    final names = RegExp(r'"sis\.[a-z.]+"')
        .allMatches(c)
        .map((m) => m[0])
        .toSet();
    expect(names, {'"sis.push.delivery"'}, reason: 'no other keychain item');
  });

  test('the delivery code never adds, updates or deletes a keychain item', () {
    final files = [_reader, _call, _core, _peek];
    final apis = ['SecItemAdd', 'SecItemUpdate', 'SecItemDelete'];
    for (final p in files) {
      for (final api in apis) {
        expect(_code(p), isNot(contains(api)), reason: '$p uses $api');
      }
    }
  });

  test('the delivery code never logs', () {
    final files = [_reader, _call, _core];
    final needles = [
      'print(',
      'NSLog(',
      'os_log(',
      'Logger(',
      'debugPrint(',
      'dump(',
    ];
    for (final p in files) {
      for (final needle in needles) {
        expect(
          _code(p),
          isNot(contains(needle)),
          reason: '$p logs with $needle',
        );
      }
    }
  });

  test('the delivery code never refreshes a session', () {
    final files = [_reader, _call, _core];
    final needles = ['refresh_token', 'grant_type', '/auth/v1'];
    for (final p in files) {
      for (final needle in needles) {
        expect(
          _code(p),
          isNot(contains(needle)),
          reason: '$p refreshes with $needle',
        );
      }
    }
  });

  test('the call keeps nothing on disk (no shared session)', () {
    final c = _code(_call);
    expect(c, contains('URLSessionConfiguration.ephemeral'));
    expect(c, isNot(contains('URLSession.shared')));
    expect(c, isNot(contains('URLSessionConfiguration.default')));
  });
}
