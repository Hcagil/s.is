import 'dart:developer';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/sis_app.dart';
import 'core/runtime_config.dart';
import 'features/auth/application/session_controller.dart';
import 'features/auth/data/secure_session_storage.dart';
import 'features/auth/data/supabase_auth_repository.dart';
import 'features/chat/application/chat_controllers.dart';
import 'features/chat/data/external_picker_channel.dart';
import 'features/chat/data/file_attachment_cache.dart';
import 'features/chat/data/file_chat_list_snapshot_store.dart';
import 'features/chat/data/native_picture_cropper.dart';
import 'features/chat/data/photo_manager_gallery.dart';
import 'features/chat/data/supabase_chat_repository.dart';
import 'features/chat/data/supabase_contacts_repository.dart';
import 'features/chat/data/url_launcher_link_opener.dart';
import 'features/notifications/application/alert_controller.dart';
import 'features/notifications/application/badge_controller.dart';
import 'features/notifications/application/notification_settings_controller.dart';
import 'features/notifications/application/push_controller.dart';
import 'features/notifications/data/channel_tone_picker.dart';
import 'features/notifications/data/firebase_push_source.dart';
import 'features/notifications/data/local_push_display.dart';
import 'features/notifications/data/platform_app_badge.dart';
import 'features/notifications/data/shared_prefs_alert_store.dart';
import 'features/notifications/data/shared_prefs_notification_explainer_store.dart';
import 'features/notifications/data/supabase_notification_settings_repository.dart';
import 'features/notifications/data/supabase_push_receipts.dart';
import 'features/notifications/data/supabase_push_registry.dart';
import 'features/presence/application/presence_controllers.dart';
import 'features/presence/data/supabase_presence_repository.dart';
import 'features/profile/application/profile_controller.dart';
import 'features/profile/data/supabase_profile_repository.dart';
import 'features/update/application/release_notes_controller.dart';
import 'features/update/application/update_controller.dart';
import 'features/update/data/play_update_repository.dart';
import 'features/update/data/supabase_release_notes_delivery.dart';
import 'features/update/data/testflight_update_repository.dart';

/// The provider overrides that depend on the platform: iOS sends a Google
/// nonce and updates through TestFlight; everything else is Android (Play).
List<Override> platformOverrides(
  TargetPlatform platform,
  SupabaseClient client,
  RuntimeConfig config,
) {
  final isIos = platform == TargetPlatform.iOS;
  return [
    authRepositoryProvider.overrideWithValue(
      SupabaseAuthRepository(
        client,
        GoogleSignIn.instance,
        googleWebClientId: config.googleWebClientId,
        useNonce: isIos,
      ),
    ),
    updateRepositoryProvider.overrideWithValue(
      // Play in-app updates exist on Android only; iOS is TestFlight.
      isIos ? TestFlightUpdateRepository(client) : PlayUpdateRepository(client),
    ),
    // The platform is stored with the token: iOS is sent a regular
    // notification, Android data only.
    pushRegistryProvider.overrideWithValue(
      SupabasePushRegistry(client, platform: isIos ? 'ios' : 'android'),
    ),
  ];
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The bundled fonts are OFL: their licences ship with them.
  LicenseRegistry.addLicense(() async* {
    for (final font in ['manrope', 'sora']) {
      yield LicenseEntryWithLineBreaks([
        font,
      ], await rootBundle.loadString('assets/fonts/OFL-$font.txt'));
    }
  });
  final config = RuntimeConfig.fromEnvironment();
  if (!config.isComplete) {
    runApp(const ProviderScope(child: SisApp()));
    return;
  } // SessionController yields SetupRequired
  try {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        localStorage: SecureSessionStorage(),
      ),
    );
    // Push: reads android/app/google-services.json (Android) or
    // ios/Runner/GoogleService-Info.plist (iOS), bundled at build time.
    await Firebase.initializeApp();
    // Android pushes are data only: the app shows them itself, grouped. iOS
    // is sent a regular notification and shows it through the system.
    FirebaseMessaging.onBackgroundMessage(onBackgroundPush);
    await LocalPushDisplay.init(onTap: FirebasePushSource.tapped);
    // Drops the pre-0.26 'messages' channel and any combination now unused.
    await LocalPushDisplay.pruneChannels();
    final client = Supabase.instance.client;
    final attachmentCache = FileAttachmentCache();
    runApp(
      ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          ...platformOverrides(defaultTargetPlatform, client, config),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(client, cache: attachmentCache),
          ),
          contactsRepositoryProvider.overrideWithValue(
            SupabaseContactsRepository(client),
          ),
          attachmentCacheProvider.overrideWithValue(attachmentCache),
          chatListSnapshotStoreProvider.overrideWithValue(
            FileChatListSnapshotStore(),
          ),
          galleryProvider.overrideWithValue(const PhotoManagerGallery()),
          externalPickerProvider.overrideWithValue(
            const ExternalPickerChannel(),
          ),
          pictureCropperProvider.overrideWithValue(
            const NativePictureCropper(),
          ),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(client),
          ),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(client),
          ),
          linkOpenerProvider.overrideWithValue(const UrlLauncherLinkOpener()),
          pushSourceProvider.overrideWithValue(
            FirebasePushSource(FirebaseMessaging.instance),
          ),
          pushReceiptsProvider.overrideWithValue(SupabasePushReceipts(client)),
          appBadgeProvider.overrideWithValue(const PlatformAppBadge()),
          notificationSettingsRepositoryProvider.overrideWithValue(
            SupabaseNotificationSettingsRepository(client),
          ),
          alertStoreProvider.overrideWithValue(const SharedPrefsAlertStore()),
          tonePickerProvider.overrideWithValue(const ChannelTonePicker()),
          notificationExplainerStoreProvider.overrideWithValue(
            const SharedPrefsNotificationExplainerStore(),
          ),
          releaseNotesDeliveryProvider.overrideWithValue(
            SupabaseReleaseNotesDelivery(client),
          ),
        ],
        child: const SisApp(),
      ),
    );
  } catch (e) {
    // Malformed config or a broken secure store must show a reason, not a
    // blank screen. Error text can hold config or IDs: only its type is kept.
    log('Startup failed: ${e.runtimeType}', name: 'sis.startup');
    runApp(
      ProviderScope(
        overrides: [
          startupErrorProvider.overrideWithValue(
            'SIS could not start. Please try again.',
          ),
        ],
        child: const SisApp(),
      ),
    );
  }
}
