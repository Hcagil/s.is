import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../application/session_controller.dart';

/// Signed-out screen; shows why the last attempt did not complete, if any.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key, this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SisGlow(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 24, 26, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SisLogo(size: 72),
                const SizedBox(height: 34),
                const SisWordmark(size: 88),
                const SizedBox(height: 8),
                Text(
                  'Stay in sync',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Private messages for the people on your list.',
                  style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                ),
                if (reason != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    reason!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () =>
                        ref.read(sessionControllerProvider.notifier).signIn(),
                    child: const Text('Continue with Google'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Only invited Google accounts can sign in.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
