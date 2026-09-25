import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/failure.dart';
import '../features/auth/domain/member.dart';
import '../features/auth/application/session_controller.dart';
import '../features/auth/domain/session_state.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/status_screens.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/profile/application/profile_controller.dart';
import '../features/profile/presentation/onboarding_screen.dart';
import '../features/update/application/update_controller.dart';
import '../features/update/domain/update_state.dart';
import '../features/update/presentation/update_required_screen.dart';
import 'theme.dart';

/// Set by main() when bootstrap itself fails; the gate shows the reason.
final startupErrorProvider = Provider<String?>((_) => null);

/// Root widget: theme plus the session gate.
class SisApp extends StatelessWidget {
  const SisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SIS',
      themeMode: ThemeMode.system,
      theme: sisTheme(Brightness.light),
      darkTheme: sisTheme(Brightness.dark),
      home: const SessionGate(),
    );
  }
}

/// An allowed member sees the name-and-tag screen once, then home.
class _AllowedGate extends ConsumerWidget {
  const _AllowedGate({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(ownProfileProvider)) {
      AsyncData(:final value) when !value.onboardingDone => OnboardingScreen(
        profile: value,
      ),
      AsyncData() => HomeScreen(member: member),
      AsyncError(:final error) => StatusScreen.error(
        error is Failure ? error.message : '$error',
        onRetry: () => ref.read(ownProfileProvider.notifier).retry(),
      ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}

/// Chooses the screen from the update policy first, then the session state.
class SessionGate extends ConsumerStatefulWidget {
  const SessionGate({super.key});

  @override
  ConsumerState<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends ConsumerState<SessionGate> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // A build released, or a flexible download finished, while the app was
    // backgrounded is otherwise never seen again without a restart.
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(updateControllerProvider.notifier).recheck(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startupError = ref.watch(startupErrorProvider);
    if (startupError != null) return StartupFailedScreen(startupError);

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
      AsyncData(value: Allowed(:final member)) => _AllowedGate(member: member),
      AsyncError(:final error) => StatusScreen.error(
        '$error',
        onRetry: notifier.retry,
      ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}
