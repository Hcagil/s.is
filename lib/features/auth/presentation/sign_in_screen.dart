import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/session_controller.dart';

/// Signed-out screen; shows why the last attempt did not complete, if any.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key, this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.forum_outlined, size: 48),
                const SizedBox(height: 16),
                Text('Stay in sync', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  'Sign in with an approved Google account.',
                  textAlign: TextAlign.center,
                ),
                if (reason != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    reason!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () =>
                      ref.read(sessionControllerProvider.notifier).signIn(),
                  child: const Text('Continue with Google'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
