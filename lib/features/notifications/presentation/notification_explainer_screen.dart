import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../../l10n/app_localizations.dart';
import '../application/push_controller.dart';

/// Shown once, right after onboarding: why SIS is about to ask for
/// notification permission. "Continue" is the only way through it, and is
/// also what triggers the platform's own permission prompt.
class NotificationExplainerScreen extends ConsumerWidget {
  const NotificationExplainerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SisLogo(size: 56),
              const SizedBox(height: 24),
              Text(
                AppLocalizations.of(context).notifExplainerTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 32),
              FilledButton(
                key: const ValueKey('notification-explainer-continue'),
                onPressed: () => ref
                    .read(notificationExplainerProvider.notifier)
                    .continueAndAskPermission(),
                child: Text(AppLocalizations.of(context).commonContinue),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
