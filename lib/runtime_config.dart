class RuntimeConfig {
  const RuntimeConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.googleWebClientId,
  });

  factory RuntimeConfig.fromEnvironment() {
    return const RuntimeConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      googleWebClientId: String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
    );
  }

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String googleWebClientId;

  bool get isComplete {
    final apiUri = Uri.tryParse(supabaseUrl);
    return supabasePublishableKey.isNotEmpty &&
        apiUri != null &&
        (apiUri.scheme == 'https' || apiUri.scheme == 'http') &&
        apiUri.host.isNotEmpty &&
        googleWebClientId.endsWith('.apps.googleusercontent.com');
  }
}
