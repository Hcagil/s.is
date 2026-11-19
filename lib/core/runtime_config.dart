class RuntimeConfig {
  const RuntimeConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.googleWebClientId,
    this.mapsApiKey = '',
    this.inviteLinkBase = '',
  });

  factory RuntimeConfig.fromEnvironment() {
    return const RuntimeConfig(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      googleWebClientId: String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      mapsApiKey: String.fromEnvironment('MAPS_API_KEY'),
      inviteLinkBase: String.fromEnvironment('INVITE_LINK_BASE'),
    );
  }

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String googleWebClientId;

  /// The Google Maps key of this platform's build; empty when the build has
  /// none (the app then uses OpenStreetMap). Not required: [isComplete]
  /// ignores it.
  final String mapsApiKey;

  /// The web address invite links start with, without a trailing slash; empty for now (the invite is then the bare code, pasted into the app). Filling it in later makes links tappable; not required: [isComplete] ignores it.
  final String inviteLinkBase;

  bool get isComplete =>
      supabaseUrl.isNotEmpty &&
      supabasePublishableKey.isNotEmpty &&
      googleWebClientId.isNotEmpty;
}
