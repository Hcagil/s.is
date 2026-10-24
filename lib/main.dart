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
import 'package:http/http.dart' as http;
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
import 'features/chat/application/link_preview_controller.dart';
import 'features/chat/application/encrypted_reply_controller.dart';
import 'features/chat/application/share_controller.dart';
import 'features/chat/application/message_opener.dart';
import 'features/chat/application/reaction_opener.dart';
import 'features/chat/application/text_locker.dart';
import 'features/chat/data/external_picker_channel.dart';
import 'features/chat/data/file_video_importer.dart';
import 'features/chat/data/method_channel_encrypted_reply.dart';
import 'features/chat/data/method_channel_share_intake.dart';
import 'features/chat/data/file_attachment_cache.dart';
import 'features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'features/chat/data/store/drift_message_store.dart';
import 'features/chat/data/store/drift_read_mark_store.dart';
import 'features/chat/data/store/drift_reaction_store.dart';
import 'features/chat/data/store/legacy_chat_list.dart';
import 'features/chat/data/store/drift_send_queue_store.dart';
import 'features/chat/data/store/legacy_send_queue.dart';
import 'features/chat/data/store/store_key.dart';
import 'features/chat/data/store/store_location.dart';
import 'features/chat/data/flutter_device_files.dart';
import 'features/chat/data/flutter_device_videos.dart';
import 'features/chat/data/geolocator_device_location.dart';
import 'features/chat/data/maps_backend.dart';
import 'features/chat/data/flutter_phone_book.dart';
import 'features/chat/data/http_link_preview_fetcher.dart';
import 'features/chat/data/imcodec_sticker_encoder.dart';
import 'features/chat/data/link_image_shrink.dart';
import 'features/chat/data/native_picture_cropper.dart';
import 'features/chat/data/ui_photo_crop_renderer.dart';
import 'features/chat/data/native_sticker_cutter.dart';
import 'features/chat/data/no_voice_transcriber.dart';
import 'features/chat/data/photo_manager_gallery.dart';
import 'features/chat/data/photo_manager_video_gallery.dart';
import 'features/chat/data/record_voice_recorder.dart';
import 'features/chat/data/share_plus_text_sharer.dart';
import 'features/chat/data/share_plus_video_sharer.dart';
import 'features/chat/data/shared_prefs_contacts_disclosure_store.dart';
import 'features/chat/data/shared_prefs_played_voice_store.dart';
import 'features/chat/data/shared_prefs_recent_sticker_store.dart';
import 'features/chat/data/speech_dictation.dart';
import 'features/chat/data/supabase_admin_chat_repository.dart';
import 'features/chat/data/supabase_chat_archive_repository.dart';
import 'features/chat/data/supabase_chat_delete_repository.dart';
import 'features/chat/data/supabase_chat_file_repository.dart';
import 'features/chat/data/supabase_chat_pin_repository.dart';
import 'features/chat/data/supabase_group_settings_repository.dart';
import 'features/chat/data/supabase_chat_repository.dart';
import 'features/chat/data/supabase_encrypted_message_repository.dart';
import 'features/chat/data/supabase_location_share_repository.dart';
import 'features/chat/data/url_launcher_maps_opener.dart';
import 'features/chat/data/supabase_poll_repository.dart';
import 'features/chat/data/supabase_reaction_repository.dart';
import 'features/chat/data/supabase_sticker_repository.dart';
import 'features/chat/data/supabase_contacts_repository.dart';
import 'features/crypto/application/key_directory_controller.dart';
import 'features/crypto/data/drift_olm_pickle_store.dart';
import 'features/crypto/data/drift_session_engine.dart';
import 'features/crypto/data/keychain_group.dart';
import 'features/crypto/data/olm_key_engine.dart';
import 'features/crypto/data/pickle_key.dart';
import 'features/crypto/data/pickle_key_guard.dart';
import 'features/crypto/data/supabase_key_directory.dart';
import 'features/chat/data/supabase_contact_share_repository.dart';
import 'features/chat/data/url_launcher_link_opener.dart';
import 'features/chat/data/video_player_playback.dart';
import 'features/chat/data/webview_video_embed.dart';
import 'features/chat/presentation/map_providers.dart';
import 'features/chat/presentation/video_player_page.dart';
import 'features/chat/presentation/video_player_sheet.dart';
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
  // The starter stickers are Noto Emoji images: Apache 2.0, credit included.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Noto Emoji images',
    ], await rootBundle.loadString('assets/stickers/NOTO-EMOJI-LICENSE.txt'));
  });
  // The on-phone message store is encrypted with SQLite3 Multiple Ciphers
  // (MIT, plus ISC and BSD parts).
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['SQLite3 Multiple Ciphers'],
      await rootBundle.loadString(
        'assets/licenses/SQLITE3-MULTIPLE-CIPHERS-LICENSE.txt',
      ),
    );
  });
  final config = RuntimeConfig.fromEnvironment();
  // iPhone: the keychain group of the store and pickle keys (null elsewhere); the app moved the keys there before Flutter started.
  final keychainGroup = await cryptoKeychainGroup();
  // Before the store opens: a store whose Olm pickle key is gone is set aside (renamed), never deleted.
  if (keychainGroup != null) {
    await guardLostPickleKey(
      group: keychainGroup,
      file: await storeFile(),
      storeKey: StoreKey.inGroup(keychainGroup),
      pickleKey: PickleKey.inGroup(keychainGroup),
    );
  }
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
    // Realtime re-joins and foreground pushes reach the app through these (LiveCatchUp).
    final rejoined = StreamController<void>.broadcast();
    final foregroundPush = StreamController<String>.broadcast();
    final pushReady = Completer<PushSource>();
    // A failed setup is logged by _setUpPush and surfaces in each waiting call.
    pushReady.future.ignore();
    final client = Supabase.instance.client;
    final maps = MapsBackend(
      apiKey: config.mapsApiKey,
      client: http.Client(),
      languageCode:
          WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );
    final attachmentCache = FileAttachmentCache();
    final deviceFiles = FlutterDeviceFiles();
    // Drops the old chat_list.json (may hold message text); keeps the push feed.
    unawaited(deleteLegacyChatList());
    StartupMarks.mark('run-app');
    // The store messageStoreProvider built last: the chat-list store shares that
    // very instance (it rebuilds with it, see below).
    DriftMessageStore? builtStore;

    // A missing pickle key is never replaced while pickles are stored (a new key would lock them for good).
    final pickleKey = PickleKey.inGroup(
      keychainGroup,
      hasPickles: () async =>
          builtStore != null &&
          await DriftOlmPickleStore(builtStore!).load() != null,
    );

    // One Olm engine for key publishing and for sessions.
    final olm = OlmKeyEngine();
    runApp(
      ProviderScope(
        overrides: [
          ...appearanceOverrides,
          ...autoDownloadOverrides,
          runtimeConfigProvider.overrideWithValue(config),
          ...platformOverrides(defaultTargetPlatform, client, config),
          realtimeRejoinedProvider.overrideWithValue(rejoined.stream),
          cancelPendingJoinProvider.overrideWith(
            (ref) =>
                (id) =>
                    (ref.read(chatRepositoryProvider) as SupabaseChatRepository)
                        .cancelJoin(id),
          ),
          foregroundPushProvider.overrideWithValue(foregroundPush.stream),
          chatRepositoryProvider.overrideWith(
            (ref) => SupabaseChatRepository(
              client,
              cache: attachmentCache,
              onRejoin: () => rejoined.add(null),
              // Every read of server rows opens locked texts here, once.
              opener: ref.read(messageOpenerProvider),
            ),
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
          reactionRepositoryProvider.overrideWith(
            (ref) => SupabaseReactionRepository(
              client,
              // Locked reactions are opened here, once.
              opener: ref.read(reactionOpenerProvider),
            ),
          ),
          adminChatRepositoryProvider.overrideWithValue(
            SupabaseAdminChatRepository(client),
          ),
          pollRepositoryProvider.overrideWithValue(
            SupabasePollRepository(client),
          ),
          contactsDisclosureStoreProvider.overrideWithValue(
            SharedPrefsContactsDisclosureStore(
              () => client.auth.currentUser?.id,
            ),
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
          textSharerProvider.overrideWithValue(const SharePlusTextSharer()),
          videoSharerProvider.overrideWithValue(const SharePlusVideoSharer()),
          voiceRecorderProvider.overrideWith((ref) {
            final recorder = RecordVoiceRecorder();
            ref.onDispose(recorder.dispose);
            return recorder;
          }),
          voiceTranscriberProvider.overrideWithValue(
            const NoVoiceTranscriber(),
          ),
          dictationProvider.overrideWithValue(SpeechDictation()),
          voicePlaybackFactoryProvider.overrideWithValue(
            const VoicePlayerPlaybackFactory(),
          ),
          playedVoiceStoreProvider.overrideWithValue(
            const SharedPrefsPlayedVoiceStore(),
          ),
          // The send queue lives in the encrypted store, with the ciphertext of locked texts.
          sendQueueStoreProvider.overrideWith((ref) {
            ref.watch(messageStoreProvider);
            final queue = DriftSendQueueStore(builtStore!);
            final owner = ref.watch(currentUserIdProvider);
            // What the old build kept in preferences moves into the store once.
            if (owner != null) unawaited(moveLegacySendQueue(queue, owner));
            return queue;
          }),
          queuedCiphertextsProvider.overrideWith((ref) {
            ref.watch(messageStoreProvider);
            return DriftSendQueueStore(builtStore!);
          }),
          encryptedMessageRepositoryProvider.overrideWithValue(
            SupabaseEncryptedMessageRepository(client),
          ),
          stickerRepositoryProvider.overrideWithValue(
            SupabaseStickerRepository(client),
          ),
          recentStickerStoreProvider.overrideWithValue(
            const SharedPrefsRecentStickerStore(),
          ),
          videoSurfaceProvider.overrideWithValue(videoSurface),
          videoEmbedViewProvider.overrideWithValue(webViewVideoEmbed),
          locationShareRepositoryProvider.overrideWithValue(
            SupabaseLocationShareRepository(client),
          ),
          deviceLocationProvider.overrideWithValue(
            const GeolocatorDeviceLocation(),
          ),
          placeSearchProvider.overrideWithValue(maps.placeSearch),
          mapsOpenerProvider.overrideWithValue(const UrlLauncherMapsOpener()),
          mapViewProvider.overrideWithValue(maps.mapView),
          mapPreviewProvider.overrideWithValue(maps.mapPreview),
          attachmentCacheProvider.overrideWithValue(attachmentCache),
          // One encrypted database per signed-in account: the provider
          // watches the user id, so another account gets a fresh instance
          // (and the file's owner check wipes the old rows).
          messageStoreProvider.overrideWith((ref) {
            final key = StoreKey.inGroup(keychainGroup);
            final store = DriftMessageStore(
              ownerId: ref.watch(currentUserIdProvider) ?? '',
              file: storeFile,
              // iPhone: a database whose key is gone from both keychain groups is set aside (renamed), never deleted.
              key: () => key.loadOrCreate(
                setAsideStore: () async => setAsideStore(await storeFile()),
              ),
              // Sign-out erases both keys: the store key and the Olm pickle key.
              deleteKey: () async {
                await key.delete();
                await pickleKey.delete();
              },
            );
            ref.onDispose(store.close);
            builtStore = store;
            return store;
          }),
          chatListSnapshotStoreProvider.overrideWith((ref) {
            // Watching messageStoreProvider rebuilds this whenever a new store
            // is built, and that build has just set builtStore.
            ref.watch(messageStoreProvider);
            return DriftChatListSnapshotStore(builtStore!);
          }),
          reactionStoreProvider.overrideWith((ref) {
            ref.watch(messageStoreProvider);
            return DriftReactionStore(builtStore!);
          }),
          readMarkStoreProvider.overrideWith((ref) {
            ref.watch(messageStoreProvider);
            return DriftReadMarkStore(builtStore!);
          }),
          olmPickleStoreProvider.overrideWith((ref) {
            // Same rule as the chat list snapshot: rebuilt with every new store.
            ref.watch(messageStoreProvider);
            return DriftOlmPickleStore(builtStore!);
          }),
          pickleKeyStoreProvider.overrideWithValue(pickleKey),
          keyEngineProvider.overrideWithValue(olm),
          sessionEngineProvider.overrideWith((ref) {
            ref.watch(messageStoreProvider);
            return DriftSessionEngine(
              store: builtStore!,
              keys: olm,
              sessions: olm,
              pickleKey: pickleKey,
            );
          }),
          keyDirectoryProvider.overrideWithValue(SupabaseKeyDirectory(client)),
          lastSessionStoreProvider.overrideWithValue(FileLastSessionStore()),
          galleryProvider.overrideWithValue(const PhotoManagerGallery()),
          videoGalleryProvider.overrideWithValue(
            PhotoManagerVideoGallery(deviceFiles),
          ),
          externalPickerProvider.overrideWithValue(
            const ExternalPickerChannel(),
          ),
          shareIntakeProvider.overrideWithValue(MethodChannelShareIntake()),
          encryptedReplyIntakeProvider.overrideWithValue(
            MethodChannelEncryptedReply(),
          ),
          sharedVideoImporterProvider.overrideWithValue(
            FileVideoImporter(deviceFiles),
          ),
          pictureCropperProvider.overrideWithValue(
            const NativePictureCropper(),
          ),
          photoCropRendererProvider.overrideWithValue(
            const UiPhotoCropRenderer(),
          ),
          stickerCutterProvider.overrideWithValue(const NativeStickerCutter()),
          stickerEncoderProvider.overrideWithValue(
            const ImcodecStickerEncoder(),
          ),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(client),
          ),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(client),
          ),
          linkOpenerProvider.overrideWithValue(const UrlLauncherLinkOpener()),
          linkPreviewFetcherProvider.overrideWithValue(
            HttpLinkPreviewFetcher(
              linkPreviewHttpClient(),
              shrink: shrinkLinkImage,
            ),
          ),
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
        return _setUpPush(pushReady, foregroundPush.add);
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
Future<void> _setUpPush(
  Completer<PushSource> ready,
  void Function(String) onForeground,
) async {
  try {
    // Reads android/app/google-services.json (Android) or
    // ios/Runner/GoogleService-Info.plist (iOS), bundled at build time.
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(onBackgroundPush);
    await LocalPushDisplay.init(onTap: FirebasePushSource.tapped);
    ready.complete(
      FirebasePushSource(
        FirebaseMessaging.instance,
        onForeground: onForeground,
      ),
    );
    // Drops the pre-0.26 'messages' channel and any combination now unused.
    await LocalPushDisplay.pruneChannels();
  } catch (e) {
    log('Push setup failed: ${e.runtimeType}', name: 'sis.startup');
    if (!ready.isCompleted) ready.completeError(e);
  }
}
