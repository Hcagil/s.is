import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/failure.dart';
import '../core/startup_failure.dart';
import '../features/appearance/application/appearance_controller.dart';
import '../features/appearance/domain/appearance_settings.dart';
import '../features/appearance/domain/custom_theme.dart';
import '../features/appearance/domain/wallpaper.dart';
import '../features/auth/data/apple_button.dart';
import '../features/auth/domain/member.dart';
import '../features/auth/application/session_controller.dart';
import '../features/auth/domain/session_state.dart';
import '../features/auth/presentation/sign_in_screen.dart';
import '../features/auth/presentation/status_screens.dart';
import '../features/chat/application/chat_controllers.dart';
import '../features/chat/application/chat_drafts.dart';
import '../features/chat/application/encrypted_reply_controller.dart';
import '../features/chat/application/group_controller.dart';
import '../features/chat/application/share_controller.dart';
import '../features/chat/presentation/share_page.dart';
import '../features/crypto/application/key_directory_controller.dart';
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
import '../l10n/app_localizations.dart';
import 'loading.dart';
import 'route_stack.dart';
import 'theme.dart';

/// Set by main() when bootstrap itself fails; the gate shows the reason.
final startupErrorProvider = Provider<StartupFailure?>((_) => null);

/// Root widget: theme plus the session gate.
class SisApp extends ConsumerWidget {
  const SisApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final custom = look.activeCustomTheme;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SIS',
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // System: null, the locale follows the phone.
      locale: switch (look.language) {
        AppLanguage.system => null,
        AppLanguage.en => const Locale('en'),
        AppLanguage.tr => const Locale('tr'),
      },
      // A custom theme can fix light or dark and keeps it; every other theme
      // follows the member's choice (default: the phone).
      themeMode: switch (custom?.mode) {
        CustomThemeMode.light => ThemeMode.light,
        CustomThemeMode.dark => ThemeMode.dark,
        _ => switch (look.mode) {
          AppearanceMode.system => ThemeMode.system,
          AppearanceMode.light => ThemeMode.light,
          AppearanceMode.dark => ThemeMode.dark,
        },
      },
      theme: sisTheme(
        Brightness.light,
        theme: look.themeId,
        systemFont: look.systemFont,
        brand: custom == null
            ? null
            : sisBrandForCustom(
                custom,
                Brightness.light,
                wallpaperSet: look.wallpaper.kind != WallpaperKind.none,
              ),
      ),
      darkTheme: sisTheme(
        Brightness.dark,
        theme: look.themeId,
        systemFont: look.systemFont,
        brand: custom == null
            ? null
            : sisBrandForCustom(
                custom,
                Brightness.dark,
                wallpaperSet: look.wallpaper.kind != WallpaperKind.none,
              ),
      ),
      navigatorObservers: [ref.read(routeStackProvider)],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: sisTextScaler(
            MediaQuery.textScalerOf(context),
            look.appTextSize.scale,
          ),
        ),
        child: child!,
      ),
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
    // The language the app shows (Settings choice, or the phone's), told to the server for the SIS Destek bot.
    ref.watch(
      appLanguageSyncProvider(Localizations.localeOf(context).languageCode),
    );
    return switch (ref.watch(ownProfileProvider)) {
      AsyncData(:final value) when !value.onboardingDone => OnboardingScreen(
        profile: value,
      ),
      // Shown once, before the first Home: while it is still loading or
      // failed to load, Home wins -- this must never block the app.
      AsyncData()
          when ref.watch(notificationExplainerShownProvider).value == false =>
        const NotificationExplainerScreen(),
      AsyncData() => ShareHost(child: HomeScreen(member: member)),
      // The marker said the first-run screen is done, so Home shows while the
      // profile loads or fails to load; never an error screen.
      AsyncError() when onboarded => ShareHost(
        child: HomeScreen(member: member),
      ),
      AsyncError(:final error) => StatusScreen.error(
        failureReason(error),
        onRetry: () => ref.read(ownProfileProvider.notifier).retry(),
      ),
      _ when onboarded => ShareHost(child: HomeScreen(member: member)),
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
    // Already Allowed at startup: the listener in build only sees changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(sessionControllerProvider).value is Allowed) {
        unawaited(ref.read(storeSyncProvider).run());
      }
    });
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
        unawaited(ref.read(keyDirectoryControllerProvider.notifier).refresh());
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
    // Publishes this phone's encryption keys once the session is confirmed.
    ref.watch(keyDirectoryControllerProvider);
    // Held from the start, signed in or not: what another app shared waits
    // here until the member has signed in and picks chats (ShareHost).
    ref.listen(pendingShareProvider, (_, _) {});
    // Replies typed into private-chat notifications are sent from here.
    ref.watch(encryptedReplySenderProvider);
    // A session that ends -- signed out, or Denied (revoked, replaced, found
    // out only after the stored list was shown) -- leaves no page open: a chat
    // opened from a notification in the unconfirmed window must not stay on
    // top of the Denied or sign-in screen. Synchronous on purpose (same frame).
    // Signed in or restored: the phone's message store catches up and, on a new
    // phone, starts its fill. (Already Allowed at startup: see initState.)
    ref.listen(sessionControllerProvider, (prev, next) {
      final v = next.value;
      if (v is Allowed && prev?.value is! Allowed) {
        unawaited(ref.read(storeSyncProvider).run());
      }
      // What a member was about to share must not wait for the next account: finish it (and delete its files)
      // when the signed-in member signs out or another member signs in. A share that arrived before any
      // sign-in is kept, so sign-in first and then continue works. A refresh (loading) keeps it.
      final before = prev?.value;
      final shown = ref.read(pendingShareProvider);
      if (shown != null &&
          before is Allowed &&
          (v is SignedOut ||
              v is Denied ||
              v is Replaced ||
              (v is Allowed && v.member.userId != before.member.userId))) {
        unawaited(ref.read(pendingShareProvider.notifier).finish(shown));
      }
      if ((v is SignedOut || v is Denied || v is Replaced) && mounted) {
        // No transition: chat content must not stay visible, even sliding
        // out, over the Denied or sign-in screen.
        ref.read(routeStackProvider).removeAllAboveFirst();
      }
      if (v is Replaced && prev?.value is! Replaced) {
        // Stop push while this phone's session still exists, then end it. The
        // server already sends this phone nothing; this also tidies the token.
        final push = ref.read(pushRegistrationProvider.notifier);
        final session = ref.read(sessionControllerProvider.notifier);
        final store = ref.read(sendQueueStoreProvider);
        final uid = v.userId;
        unawaited(() async {
          // Count first: the screen shows how many were deleted.
          try {
            if (uid != null) {
              final n = (await store.load(uid)).length;
              await store.clear();
              session.noteUnsentDeleted(n);
            } else {
              await store.clear();
            }
          } catch (_) {}
          try {
            await push.forget().timeout(const Duration(seconds: 5));
          } catch (_) {}
          await session.finishReplaced();
        }());
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
      // And the files kept from file messages.
      ref.listen(deviceFilesOwnerProvider, (_, _) {});
      // The saved send queue is forgotten the same way, and listening to the
      // queue itself brings back the sends that were waiting when the app
      // was killed.
      ref.listen(sendQueueOwnerProvider, (_, _) {});
      ref.listen(playedVoiceOwnerProvider, (_, _) {});
      ref.listen(recentStickerOwnerProvider, (_, _) {});
      ref.listen(sendQueueProvider, (_, _) {});
      // Drops a conversation's queue and draft the moment it is found to be
      // one the member has left or been removed from -- see
      // leftConversationGuardProvider's own doc for why this is silent.
      ref.listen(leftConversationGuardProvider, (_, _) {});
      // Live updates of group settings, picture, members and deletion: the
      // server nudges each member, this re-reads what changed.
      ref.listen(groupChangesListenerProvider, (_, _) {});
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
      AsyncData(value: SignedOut(:final reason, :final hiddenEmail)) =>
        SignInScreen(
          reason: reason,
          hiddenEmail: hiddenEmail,
          appleButton: appleSignInButton,
        ),
      AsyncData(value: Denied()) => StatusScreen.denied(
        onSignOut: notifier.signOut,
      ),
      AsyncData(value: Replaced(:final unsentDeleted)) => StatusScreen.replaced(
        onSignIn: notifier.signIn,
        onSignInApple: notifier.signInWithApple,
        appleButton: appleSignInButton,
        unsentDeleted: unsentDeleted,
      ),
      AsyncData(value: SessionError(:final reason)) => StatusScreen.error(
        reason,
        onRetry: notifier.retry,
      ),
      AsyncData(value: Allowed(:final member, :final onboarded)) =>
        _AllowedGate(member: member, onboarded: onboarded),
      AsyncError(:final error) => StatusScreen.error(
        failureReason(error),
        onRetry: notifier.retry,
      ),
      _ => const SisFullScreenLoader(),
    };
  }
}
