import 'package:flutter_test/flutter_test.dart';
import 'package:sis/runtime_config.dart';

void main() {
  test('accepts complete supported runtime configuration', () {
    const config = RuntimeConfig(
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: 'publishable-key',
      authRedirectUri: 'sis://login-callback',
    );

    expect(config.isComplete, isTrue);
  });

  test('rejects missing or unsupported runtime configuration', () {
    const missing = RuntimeConfig(
      supabaseUrl: '',
      supabasePublishableKey: '',
      authRedirectUri: '',
    );
    const wrongRedirect = RuntimeConfig(
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: 'publishable-key',
      authRedirectUri: 'other://callback',
    );

    expect(missing.isComplete, isFalse);
    expect(wrongRedirect.isComplete, isFalse);
  });
}
