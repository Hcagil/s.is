import 'dart:async';
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
import 'core/startup_failure.dart';
import 'core/startup_marks.dart';
import 'features/appearance/application/appearance_controller.dart';
import 'features/appearance/data/picker_wallpaper_photos.dart';
import 'features/appearance/data/shared_prefs_appearance_store.dart';
import 'features/autodownload/application/auto_download_controller.dart';
import 'features/autodownload/data/connectivity_network_probe.dart';
import 'features/autodownload/data/shared_prefs_auto_download_store.dart';
import 'features/auth/application/session_controller.dart';
import 'features/auth/data/file_last_session_store.dart';
import 'features/auth/data/secure_session_storage.dart';
import 'features/auth/data/supabase_auth_repository.dart';
import 'features/chat/application/chat_controllers.dart';
import 'features/chat/data/external_picker_channel.dart';
import 'features/chat/data/file_attachment_cache.dart';
import 'features/chat/data/file_chat_list_snapshot_store.dart';
import 'features/chat/data/flutter_device_files.dart';
import 'features/chat/data/flutter_device_videos.dart';
import 'features/chat/data/flutter_phone_book.dart';
import 'features/chat/data/native_picture_cropper.dart';
import 'features/chat/data/photo_manager_gallery.dart';
import 'features/chat/data/share_plus_video_sharer.dart';
import 'features/chat/data/shared_prefs_send_queue_store.dart';
import 'features/chat/data/supabase_chat_archive_repository.dart';
import 'features/chat/data/supabase_chat_delete_repository.dart';
import 'features/chat/data/supabase_chat_file_repository.dart';
import 'features/chat/data/supabase_chat_pin_repository.dart';
import 'features/chat/data/supabase_group_settings_repository.dart';
import 'features/chat/data/supabase_chat_repository.dart';
import 'features/chat/data/supabase_poll_repository.dart';
import 'features/chat/data/supabase_reaction_repository.dart';
import 'features/chat/data/supabase_contacts_repository.dart';
import 'features/chat/data/supabase_contact_share_repository.dart';
import 'features/chat/data/url_launcher_link_opener.dart';
import 'features/chat/data/video_player_playback.dart';
import 'features/notifications/application/alert_controller.dart';
import 'features/notifications/application/badge_controller.dart';
import 'features/notifications/application/notification_settings_controller.dart';
import 'features/notifications/application/push_controller.dart';
import 'features/notifications/data/channel_tone_picker.dart';
import 'features/notifications/data/deferred_push_source.dart';
import 'features/notifications/data/firebase_push_source.dart';
import 'features/notifications/data/local_push_display.dart';
import 'features/notifications/data/platform_app_badge.dart';
import 'features/notifications/data/shared_prefs_alert_store.dart';
import 'features/notifications/data/shared_prefs_notification_explainer_store.dart';
import 'features/notifications/data/supabase_notification_settings_repository.dart';
import 'features/notifications/data/supabase_push_receipts.dart';
import 'features/notifications/data/supabase_push_registry.dart';
import 'features/notifications/domain/push.dart';
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
  StartupMarks.mark('main');
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
  // Read before runApp (like the session marker), so the first frame already
  // has the member's theme, font, text size and language: no flash.
  const appearanceStore = SharedPrefsAppearanceStore();
  final appearanceOverrides = [
    appearanceStoreProvider.overrideWithValue(appearanceStore),
    initialAppearanceProvider.overrideWithValue(await appearanceStore.load()),
    wallpaperPhotosProvider.overrideWithValue(
      const PickerWallpaperPhotos(ExternalPickerChannel()),
    ),
  ];
  // Same reason: the member's auto-download choices are known at the first
  // frame, so a photo's gate never flickers.
  const autoDownloadStore = SharedPrefsAutoDownloadStore();
  final autoDownloadOverrides = [
    autoDownloadStoreProvider.overrideWithValue(autoDownloadStore),
    initialAutoDownloadProvider.overrideWithValue(
      await autoDownloadStore.load(),
    ),
    networkProbeProvider.overrideWithValue(ConnectivityNetworkProbe()),
  ];
  if (!config.isComplete) {
    runApp(
      ProviderScope(overrides: appearanceOverrides, child: const SisApp()),
    );
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
    StartupMarks.mark('supabase-ready');
    // Push is set up after the first frame (see below); everything that asks
    // the push source waits for it (DeferredPushSource).
    final pushReady = Completer<PushSource>();
    // A failed setup is logged by _setUpPush and surfaces in each waiting call.
    pushReady.future.ignore();
    final client = Supabase.instance.client;
    final attachmentCache = FileAttachmentCache();
    final deviceFiles = FlutterDeviceFiles();
    StartupMarks.mark('run-app');
    runApp(
      ProviderScope(
        overrides: [
          ...appearanceOverrides,
          ...autoDownloadOverrides,
          runtimeConfigProvider.overrideWithValue(config),
          ...platformOverrides(defaultTargetPlatform, client, config),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(client, cache: attachmentCache),
          ),
          groupSettingsRepositoryProvider.overrideWithValue(
            SupabaseGroupSettingsRepository(client),
          ),
          chatArchiveRepositoryProvider.overrideWithValue(
            SupabaseChatArchiveRepository(client),
          ),
          chatPinRepositoryProvider.overrideWithValue(
            SupabaseChatPinRepository(client),
          ),
          chatDeleteRepositoryProvider.overrideWithValue(
            SupabaseChatDeleteRepository(client),
          ),
          reactionRepositoryProvider.overrideWithValue(
            SupabaseReactionRepository(client),
          ),
          pollRepositoryProvider.overrideWithValue(
            SupabasePollRepository(client),
          ),
          contactsRepositoryProvider.overrideWithValue(
            SupabaseContactsRepository(client),
          ),
          contactShareRepositoryProvider.overrideWithValue(
            SupabaseContactShareRepository(client),
          ),
          phoneBookProvider.overrideWithValue(const FlutterPhoneBook()),
          chatFileRepositoryProvider.overrideWithValue(
            SupabaseChatFileRepository(client),
          ),
          deviceFilesProvider.overrideWithValue(deviceFiles),
          deviceVideosProvider.overrideWithValue(
            FlutterDeviceVideos(deviceFiles),
          ),
          videoPlaybackFactoryProvider.overrideWithValue(
            const VideoPlayerPlaybackFactory(),
          ),
          videoSharerProvider.overrideWithValue(const SharePlusVideoSharer()),
          sendQueueStoreProvider.overrideWithValue(
            const SharedPrefsSendQueueStore(),
          ),
          videoSurfaceProvider.overrideWithValue(videoSurface),
          attachmentCacheProvider.overrideWithValue(attachmentCache),
          chatListSnapshotStoreProvider.overrideWithValue(
            FileChatListSnapshotStore(),
          ),
          lastSessionStoreProvider.overrideWithValue(FileLastSessionStore()),
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
            DeferredPushSource(pushReady.future),
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
    unawaited(
      WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
        StartupMarks.mark('first-frame');
        return _setUpPush(pushReady);
      }),
    );
  } catch (e) {
    // Malformed config or a broken secure store must show a reason, not a
    // blank screen. Error text can hold config or IDs: only its type is kept.
    log('Startup failed: ${e.runtimeType}', name: 'sis.startup');
    runApp(
      ProviderScope(
        overrides: [
          ...appearanceOverrides,
          startupErrorProvider.overrideWithValue(StartupFailure.bootstrap),
        ],
        child: const SisApp(),
      ),
    );
  }
}

/// Firebase and the local notification display, set up once the first frame is
/// on screen: nothing on that frame needs them, and they cost start-up time.
/// Android pushes are data only (the app shows them itself, grouped); iOS is
/// sent a regular notification and shows it through the system.
Future<void> _setUpPush(Completer<PushSource> ready) async {
  try {
    // Reads android/app/google-services.json (Android) or
    // ios/Runner/GoogleService-Info.plist (iOS), bundled at build time.
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(onBackgroundPush);
    await LocalPushDisplay.init(onTap: FirebasePushSource.tapped);
    ready.complete(FirebasePushSource(FirebaseMessaging.instance));
    // Drops the pre-0.26 'messages' channel and any combination now unused.
    await LocalPushDisplay.pruneChannels();
  } catch (e) {
    log('Push setup failed: ${e.runtimeType}', name: 'sis.startup');
    if (!ready.isCompleted) ready.completeError(e);
  }
}
