class RuntimeConfig {
  const RuntimeConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.authRedirectUri,
  });

  factory RuntimeConfig.fromEnvironment() {
    return const RuntimeConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      authRedirectUri: String.fromEnvironment('AUTH_REDIRECT_URI'),
    );
  }

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String authRedirectUri;

  bool get isComplete {
    final apiUri = Uri.tryParse(supabaseUrl);
    final redirectUri = Uri.tryParse(authRedirectUri);
    return supabasePublishableKey.isNotEmpty &&
        apiUri != null &&
        (apiUri.scheme == 'https' || apiUri.scheme == 'http') &&
        apiUri.host.isNotEmpty &&
        redirectUri != null &&
        redirectUri.scheme == 'sis' &&
        redirectUri.host == 'login-callback';
  }
}
