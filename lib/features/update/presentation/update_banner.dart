import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/theme.dart';
import '../application/update_controller.dart';
import '../domain/update_state.dart';

/// Dismissible banner for flexible updates; renders nothing when idle.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider).value;
    final notifier = ref.read(updateControllerProvider.notifier);
    final child = switch (state) {
      UpdateAvailableFlexible() => Row(
        children: [
          const Expanded(child: Text('Update available')),
          TextButton(onPressed: notifier.dismiss, child: const Text('Later')),
          TextButton(onPressed: notifier.download, child: const Text('Update')),
        ],
      ),
      UpdateDownloading() => const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Downloading update…'),
          SizedBox(height: 8),
          SisProgressLine(),
        ],
      ),
      UpdateReadyToInstall() => Row(
        children: [
          const Expanded(child: Text('Ready to install')),
          TextButton(onPressed: notifier.install, child: const Text('Restart')),
        ],
      ),
      _ => null,
    };
    if (child == null) return const SizedBox.shrink();
    final t = SisBrand.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: t.text),
          child: child,
        ),
      ),
    );
  }
}
