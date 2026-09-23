import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../application/profile_controller.dart';
import 'profile_form.dart';

Future<void> _setSharing(
  BuildContext context,
  WidgetRef ref, {
  bool? presence,
  bool? typing,
}) async {
  final result = await ref
      .read(ownProfileProvider.notifier)
      .setSharing(presence: presence, typing: typing);
  if (result case Err(:final failure) when context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(failure.message)));
  }
}

/// Account settings: display name, tag, and what others can see.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(ownProfileProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: switch (profile) {
          AsyncData(:final value) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Profile', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              ProfileForm(
                // Rebuilt from the saved profile, so the fields show what is
                // stored rather than what was typed.
                key: ValueKey('${value.displayName}|${value.tag}'),
                profile: value,
                submitLabel: 'Save',
                onSubmit: (name, tag) async {
                  final result = await ref
                      .read(ownProfileProvider.notifier)
                      .save(displayName: name, tag: tag);
                  if (result is Ok && context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Saved')));
                  }
                  return result;
                },
              ),
              const SizedBox(height: 32),
              Text('Privacy', style: Theme.of(context).textTheme.titleMedium),
              SwitchListTile(
                key: const ValueKey('share-presence'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show when I am online'),
                value: value.sharePresence,
                onChanged: (on) => _setSharing(context, ref, presence: on),
              ),
              SwitchListTile(
                key: const ValueKey('share-typing'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show when I am typing'),
                value: value.shareTyping,
                onChanged: (on) => _setSharing(context, ref, typing: on),
              ),
            ],
          ),
          AsyncError(:final error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    error is Failure ? error.message : '$error',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(ownProfileProvider.notifier).retry(),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}
