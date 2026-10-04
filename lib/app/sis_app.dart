import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/failure.dart';
import '../features/auth/domain/member.dart';
import '../features/auth/application/session_controller.dart';
import '../features/auth/domain/session_state.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/status_screens.dart';
import '../features/chat/application/chat_controllers.dart';
import '../features/chat/application/chat_drafts.dart';
import '../features/chat/application/group_controller.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/notifications/application/badge_controller.dart';
import '../features/notifications/application/push_controller.dart';
import '../features/notifications/presentation/notification_explainer_screen.dart';
import '../features/profile/application/profile_controller.dart';
import '../features/profile/presentation/onboarding_screen.dart';
import '../features/update/application/release_notes_controller.dart';
import '../features/update/application/update_controller.dart';
import '../features/update/domain/update_state.dart';
import '../features/update/presentation/update_required_screen.dart';
import 'loading.dart';
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
  const _AllowedGate({required this.member, required this.onboarded});

  final Member member;
  final bool onboarded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Starts alongside the profile load below rather than only once Home is
    // reached, so the two round trips race instead of running one after the
    // other. Its value is unused here; HomeScreen reads it once shown.
    ref.listen(conversationListProvider, (_, _) {});
    return switch (ref.watch(ownProfileProvider)) {
      AsyncData(:final value) when !value.onboardingDone => OnboardingScreen(
        profile: value,
      ),
      // Shown once, before the first Home: while it is still loading or
      // failed to load, Home wins -- this must never block the app.
      AsyncData()
          when ref.watch(notificationExplainerShownProvider).value == false =>
        const NotificationExplainerScreen(),
      AsyncData() => HomeScreen(member: member),
      // The marker said the first-run screen is done, so Home shows while the
      // profile loads or fails to load; never an error screen.
      AsyncError() when onboarded => HomeScreen(member: member),
      AsyncError(:final error) => StatusScreen.error(
        error is Failure ? error.message : '$error',
        onRetry: () => ref.read(ownProfileProvider.notifier).retry(),
      ),
      _ when onboarded => HomeScreen(member: member),
      _ => const SisFullScreenLoader(),
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
    // backgrounded is otherwise never seen again without a restart. Queued
    // sends resume the same way: paused while backgrounded, retried at once
    // for every waiting chat on return (see SendQueueController.pauseForBackground
    // / resumeForeground) rather than waiting out whatever backoff delay was
    // left.
    _lifecycle = AppLifecycleListener(
      // Visible again after being backgrounded: Realtime died meanwhile, so
      // the open chat and the list fetch what they missed.
      onShow: () {
        ref.read(appVisibleProvider.notifier).set(true);
        ref.read(resumeCatchUpProvider)();
        // The icon number is re-read on every return, never left stale.
        ref.read(badgeSyncProvider)();
      },
      onResume: () {
        // An unconfirmed session asks the server again at once.
        ref.read(sessionControllerProvider.notifier).recheck();
        ref.read(updateControllerProvider.notifier).recheck();
        ref.read(sendQueueProvider.notifier).resumeForeground();
      },
      onHide: () {
        ref.read(appVisibleProvider.notifier).set(false);
        ref.read(sendQueueProvider.notifier).pauseForBackground();
      },
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

    final session = ref.watch(sessionControllerProvider);
    // A session that ends -- signed out, or Denied (revoked, replaced, found
    // out only after the stored list was shown) -- leaves no page open: a chat
    // opened from a notification in the unconfirmed window must not stay on
    // top of the Denied or sign-in screen. Synchronous on purpose (same frame).
    ref.listen(sessionControllerProvider, (_, next) {
      final v = next.value;
      if ((v is SignedOut || v is Denied) && mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    });
    // For the life of the app, whatever screen it is on: keeps this phone on
    // the delivery list for whoever is signed in, and drops what a previous
    // member's pushes left on it as soon as their session is found to have
    // ended -- on any path, a cold start onto sign-in or Denied included.
    // Not before the session is past SetupRequired: pushSourceProvider is
    // only overridden once config is complete, and this must not be built
    // in the config-incomplete or startup-failure run of the app.
    if (session.value != null && session.value is! SetupRequired) {
      ref.listen(pushRegistrationProvider, (_, _) {});
      // Same reach as the line above, for photos and pictures instead of
      // notifications: attachmentCacheOwnerProvider clears the shared cache
      // on any path a session can end on, not only the explicit sign-out
      // button.
      ref.listen(attachmentCacheOwnerProvider, (_, _) {});
      // Same reach again, for the stored chat list: chatListSnapshotOwnerProvider
      // erases it on any path a session can end on, not only sign-out.
      ref.listen(chatListSnapshotOwnerProvider, (_, _) {});
      // Drops a conversation's queue and draft the moment it is found to be
      // one the member has left or been removed from -- see
      // leftConversationGuardProvider's own doc for why this is silent.
      ref.listen(leftConversationGuardProvider, (_, _) {});
      // Asks for the What's new notes due for this build once per start,
      // for whoever is signed in.
      ref.listen(releaseNotesProvider, (_, _) {});
      // The app-icon unread number follows the chat list for whoever is
      // signed in (and clears when nobody is).
      ref.listen(badgeSyncProvider, (_, _) {});
    }

    final update = ref.watch(updateControllerProvider).value;
    if (update case UpdateRequired(:final installed, :final minimum)) {
      return UpdateRequiredScreen(installed: installed, minimum: minimum);
    }

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
      AsyncData(value: Allowed(:final member, :final onboarded)) =>
        _AllowedGate(member: member, onboarded: onboarded),
      AsyncError(:final error) => StatusScreen.error(
        '$error',
        onRetry: notifier.retry,
      ),
      _ => const SisFullScreenLoader(),
    };
  }
}
