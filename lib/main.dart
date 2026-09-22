import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/sis_app.dart';
import 'core/runtime_config.dart';
import 'features/auth/application/session_controller.dart';
import 'features/auth/data/secure_session_storage.dart';
import 'features/auth/data/supabase_auth_repository.dart';
import 'features/chat/application/chat_controllers.dart';
import 'features/chat/data/image_picker_attachment_source.dart';
import 'features/chat/data/supabase_chat_repository.dart';
import 'features/profile/application/profile_controller.dart';
import 'features/profile/data/supabase_profile_repository.dart';
import 'features/update/application/update_controller.dart';
import 'features/update/data/play_update_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    final client = Supabase.instance.client;
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
            SupabaseChatRepository(client),
          ),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(client),
          ),
          attachmentSourceProvider.overrideWithValue(
            ImagePickerAttachmentSource(ImagePicker()),
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
