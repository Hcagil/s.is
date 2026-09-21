import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';

void main() {
  test('Result pattern-matches', () {
    const Result<int> r = Ok(3);
    final v = switch (r) {
      Ok(:final value) => value,
      Err() => -1,
    };
    expect(v, 3);
  });

  test('ProviderFailure carries reason and cancel flag', () {
    const f = ProviderFailure('Google sign-in canceled: x', userCanceled: true);
    expect(f.message, contains('canceled'));
    expect(f.userCanceled, isTrue);
  });

  test('config is incomplete when any define is empty', () {
    const c = RuntimeConfig(
      supabaseUrl: 'https://x.supabase.co',
      supabasePublishableKey: '',
      googleWebClientId: 'id',
    );
    expect(c.isComplete, isFalse);
  });
}
