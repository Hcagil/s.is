import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/auth/application/session_controller.dart';
import '../features/auth/domain/session_state.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/status_screens.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/update/application/update_controller.dart';
import '../features/update/domain/update_state.dart';
import '../features/update/presentation/update_required_screen.dart';

/// Root widget: theme plus the session gate.
class SisApp extends StatelessWidget {
  const SisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SIS',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const SessionGate(),
    );
  }
}

/// Chooses the screen from the update policy first, then the session state.
class SessionGate extends ConsumerWidget {
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateControllerProvider).value;
    if (update case UpdateRequired(:final installed, :final minimum)) {
      return UpdateRequiredScreen(installed: installed, minimum: minimum);
    }

    final session = ref.watch(sessionControllerProvider);
    final notifier = ref.read(sessionControllerProvider.notifier);
    return switch (session) {
      AsyncData(value: SetupRequired()) => const SetupRequiredScreen(),
      AsyncData(value: SignedOut(:final reason)) => SignInScreen(
        reason: reason,
      ),
      AsyncData(value: Denied()) => StatusScreen.denied(
        onSignOut: notifier.signOut,
      ),
      AsyncData(value: SessionError(:final reason)) => StatusScreen.error(
        reason,
        onRetry: notifier.retry,
      ),
      AsyncData(value: Allowed(:final member)) => HomeScreen(member: member),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}
