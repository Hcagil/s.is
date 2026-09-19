import 'package:flutter_test/flutter_test.dart';
import 'package:sis/runtime_config.dart';

void main() {
  test('accepts complete supported runtime configuration', () {
    const config = RuntimeConfig(
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: 'publishable-key',
      googleWebClientId: 'web-client.apps.googleusercontent.com',
    );

    expect(config.isComplete, isTrue);
  });

  test('rejects missing or unsupported runtime configuration', () {
    const missing = RuntimeConfig(
      supabaseUrl: '',
      supabasePublishableKey: '',
      googleWebClientId: '',
    );
    const wrongClientId = RuntimeConfig(
      supabaseUrl: 'https://example.supabase.co',
      supabasePublishableKey: 'publishable-key',
      googleWebClientId: 'not-a-google-client',
    );

    expect(missing.isComplete, isFalse);
    expect(wrongClientId.isComplete, isFalse);
  });
}
