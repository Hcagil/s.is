import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/sis_app.dart';
import 'core/runtime_config.dart';
import 'features/auth/application/session_controller.dart';
import 'features/auth/data/secure_session_storage.dart';
import 'features/auth/data/supabase_auth_repository.dart';
import 'features/chat/application/chat_controllers.dart';
import 'features/chat/data/file_attachment_cache.dart';
import 'features/chat/data/photo_manager_gallery.dart';
import 'features/chat/data/supabase_chat_repository.dart';
import 'features/chat/data/url_launcher_link_opener.dart';
import 'features/notifications/application/notification_settings_controller.dart';
import 'features/notifications/application/push_controller.dart';
import 'features/notifications/data/firebase_push_source.dart';
import 'features/notifications/data/local_push_display.dart';
import 'features/notifications/data/shared_prefs_notification_explainer_store.dart';
import 'features/notifications/data/supabase_notification_settings_repository.dart';
import 'features/notifications/data/supabase_push_registry.dart';
import 'features/presence/application/presence_controllers.dart';
import 'features/presence/data/supabase_presence_repository.dart';
import 'features/profile/application/profile_controller.dart';
import 'features/profile/data/supabase_profile_repository.dart';
import 'features/update/application/update_controller.dart';
import 'features/update/data/play_update_repository.dart';

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
    // Push: reads android/app/google-services.json, bundled at build time.
    await Firebase.initializeApp();
    // Pushes are data only; the app shows them itself, grouped.
    FirebaseMessaging.onBackgroundMessage(onBackgroundPush);
    await LocalPushDisplay.init(onTap: FirebasePushSource.tapped);
    final client = Supabase.instance.client;
    final attachmentCache = FileAttachmentCache();
    runApp(
      ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(
            SupabaseAuthRepository(
              client,
              GoogleSignIn.instance,
              googleWebClientId: config.googleWebClientId,
            ),
          ),
          updateRepositoryProvider.overrideWithValue(
            PlayUpdateRepository(client),
          ),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(client, cache: attachmentCache),
          ),
          attachmentCacheProvider.overrideWithValue(attachmentCache),
          galleryProvider.overrideWithValue(const PhotoManagerGallery()),
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
          pushRegistryProvider.overrideWithValue(SupabasePushRegistry(client)),
          notificationSettingsRepositoryProvider.overrideWithValue(
            SupabaseNotificationSettingsRepository(client),
          ),
          notificationExplainerStoreProvider.overrideWithValue(
            const SharedPrefsNotificationExplainerStore(),
          ),
        ],
        child: const SisApp(),
      ),
    );
  } catch (e) {
    // Malformed config or a broken secure store must show a reason, not a
    // blank screen.
    runApp(
      ProviderScope(
        overrides: [startupErrorProvider.overrideWithValue('$e')],
        child: const SisApp(),
      ),
    );
  }
}
