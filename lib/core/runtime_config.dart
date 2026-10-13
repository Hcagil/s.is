class RuntimeConfig {
  const RuntimeConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.googleWebClientId,
    this.mapsApiKey = '',
  });

  factory RuntimeConfig.fromEnvironment() {
    return const RuntimeConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      googleWebClientId: String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      mapsApiKey: String.fromEnvironment('MAPS_API_KEY'),
    );
  }

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String googleWebClientId;

  /// The Google Maps key of this platform's build; empty when the build has
  /// none (the app then uses OpenStreetMap). Not required: [isComplete]
  /// ignores it.
  final String mapsApiKey;

  bool get isComplete =>
      supabaseUrl.isNotEmpty &&
      supabasePublishableKey.isNotEmpty &&
      googleWebClientId.isNotEmpty;
}
