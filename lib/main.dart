import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/sis_app.dart';
import 'core/runtime_config.dart';
import 'features/auth/application/session_controller.dart';
import 'features/auth/data/secure_session_storage.dart';
import 'features/auth/data/supabase_auth_repository.dart';
import 'features/update/application/update_controller.dart';
import 'features/update/data/play_update_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = RuntimeConfig.fromEnvironment();
  if (!config.isComplete) {
    runApp(const ProviderScope(child: SisApp()));
    return;
  } // SessionController yields SetupRequired
  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabasePublishableKey,
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      localStorage: SecureSessionStorage(),
    ),
  );
  await GoogleSignIn.instance.initialize(
    serverClientId: config.googleWebClientId,
  );
  final client = Supabase.instance.client;
  runApp(
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(
          SupabaseAuthRepository(client, GoogleSignIn.instance),
        ),
        updateRepositoryProvider.overrideWithValue(
          PlayUpdateRepository(client),
        ),
      ],
      child: const SisApp(),
    ),
  );
}
