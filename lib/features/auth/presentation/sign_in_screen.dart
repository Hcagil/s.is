import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../../l10n/app_localizations.dart';
import '../application/session_controller.dart';

/// Signed-out screen; shows why the last attempt did not complete, if any.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({
    super.key,
    this.reason,
    this.hiddenEmail = false,
    this.appleButton,
  });

  final String? reason;

  /// Apple's email was hidden: show the translated line instead of [reason].
  final bool hiddenEmail;

  /// Builds the Apple button (text, onPressed); null draws none. The widget
  /// itself lives in data/ and is supplied by the app.
  final Widget Function(String text, VoidCallback onPressed)? appleButton;

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
                  AppLocalizations.of(context).appTagline,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocalizations.of(context).signInBody,
                  style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                ),
                if (hiddenEmail || reason != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    hiddenEmail
                        ? AppLocalizations.of(context).signInHiddenEmail
                        : reason!,
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
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF222222),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: Color(0xFFD0D0D8)),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'G',
                          style: TextStyle(
                            color: Color(0xFF4285F4),
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context).signInGoogle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (appleButton != null &&
                    theme.platform == TargetPlatform.iOS) ...[
                  const SizedBox(height: 12),
                  appleButton!(
                    AppLocalizations.of(context).signInWithApple,
                    () => ref
                        .read(sessionControllerProvider.notifier)
                        .signInWithApple(),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.of(context).signInInvitedOnly,
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
