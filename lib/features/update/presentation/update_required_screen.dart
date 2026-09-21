import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/update_controller.dart';

/// Blocking screen shown only when the build is below the supported minimum.
class UpdateRequiredScreen extends ConsumerWidget {
  const UpdateRequiredScreen({
    super.key,
    required this.installed,
    required this.minimum,
  });

  final int installed;
  final int minimum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Update required',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'This version ($installed) is no longer supported '
                  '(minimum $minimum).',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () =>
                      ref.read(updateControllerProvider.notifier).updateNow(),
                  child: const Text('Update now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
