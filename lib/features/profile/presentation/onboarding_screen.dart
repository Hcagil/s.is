import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../application/profile_controller.dart';
import '../domain/own_profile.dart';
import 'profile_form.dart';

/// Shown once after sign-in: confirm how other members see you.
///
/// Skipping keeps the name from the Google account and the generated tag,
/// which is also what the fields start with.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key, required this.profile});

  final OwnProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(ownProfileProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome'),
        actions: [
          TextButton(
            key: const ValueKey('onboarding-skip'),
            onPressed: () async {
              final result = await controller.completeOnboarding();
              if (result case Err(:final failure) when context.mounted) {
                showSisNotice(context, failure.message, isError: true);
              }
            },
            child: const Text('Skip'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'How should others see you?',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text('You can change both later in Settings.'),
            const SizedBox(height: 24),
            ProfileForm(
              profile: profile,
              submitLabel: 'Continue',
              onSubmit: (name, tag) =>
                  controller.completeOnboarding(displayName: name, tag: tag),
            ),
          ],
        ),
      ),
    );
  }
}
