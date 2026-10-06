import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
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
          Expanded(child: Text(AppLocalizations.of(context).updateAvailable)),
          TextButton(
            onPressed: notifier.dismiss,
            child: Text(AppLocalizations.of(context).updateLater),
          ),
          TextButton(
            onPressed: notifier.download,
            child: Text(AppLocalizations.of(context).updateAction),
          ),
        ],
      ),
      UpdateDownloading() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context).updateDownloading),
          const SizedBox(height: 8),
          SisProgressLine(),
        ],
      ),
      UpdateReadyToInstall() => Row(
        children: [
          Expanded(child: Text(AppLocalizations.of(context).updateReady)),
          TextButton(
            onPressed: notifier.install,
            child: Text(AppLocalizations.of(context).updateRestart),
          ),
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
