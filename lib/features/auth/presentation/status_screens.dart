import 'package:flutter/material.dart';

/// A full-screen status with one action (denied, or error with retry).
class StatusScreen extends StatelessWidget {
  const StatusScreen._({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  /// Signed in with Google but not on the allowlist.
  const StatusScreen.denied({
    Key? key,
    required Future<void> Function() onSignOut,
  }) : this._(
         key: key,
         icon: Icons.lock_outline,
         title: 'Access denied',
         message: 'This Google account is not currently approved for SIS.',
         actionLabel: 'Sign out',
         onPressed: onSignOut,
       );

  /// Something failed; the reason is always shown.
  const StatusScreen.error(
    String reason, {
    Key? key,
    required Future<void> Function() onRetry,
  }) : this._(
         key: key,
         icon: Icons.cloud_off_outlined,
         title: 'Could not connect',
         message: reason,
         actionLabel: 'Try again',
         onPressed: onRetry,
       );

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => onPressed(),
                  child: Text(actionLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Runtime configuration is incomplete; the app cannot connect.
class SetupRequiredScreen extends StatelessWidget {
  const SetupRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.settings_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Setup required',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Build with SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, and '
                  'GOOGLE_WEB_CLIENT_ID to connect SIS.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bootstrap failed before any session existed; restarting is the only way out.
class StartupFailedScreen extends StatelessWidget {
  const StartupFailedScreen(this.reason, {super.key});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Could not start SIS',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Restart the app. If it keeps failing, reinstall it.\n\n$reason',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
