import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import 'appearance_labels.dart';
import 'chat_preview.dart';

class TextSizePage extends ConsumerWidget {
  const TextSizePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTextSize)),
      body: SafeArea(
        child: ListView(
          children: [
            SisSwitchTile(
              key: const ValueKey('text-system-font'),
              title: l.textSystemFont,
              subtitle: l.textSystemFontHint,
              value: look.systemFont,
              onChanged: notifier.setSystemFont,
            ),
            _Label(l.textChatSize),
            const ChatPreview(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<TextSize>(
                key: const ValueKey('text-chat-size'),
                showSelectedIcon: false,
                segments: [
                  for (final s in TextSize.values)
                    ButtonSegment(value: s, label: Text(textSizeLabel(l, s))),
                ],
                selected: {look.chatTextSize},
                onSelectionChanged: (set) =>
                    notifier.setChatTextSize(set.first),
              ),
            ),
            _Label(l.textAppSize),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                l.textAppSample,
                key: const ValueKey('text-app-sample'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<TextSize>(
                key: const ValueKey('text-app-size'),
                showSelectedIcon: false,
                segments: [
                  for (final s in TextSize.values)
                    ButtonSegment(value: s, label: Text(textSizeLabel(l, s))),
                ],
                selected: {look.appTextSize},
                onSelectionChanged: (set) => notifier.setAppTextSize(set.first),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// A section label.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: SisTokens.sectionLabelWeight,
        color: SisBrand.of(context).muted,
      ),
    ),
  );
}
