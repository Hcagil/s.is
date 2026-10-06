import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/alert_controller.dart';
import '../domain/alert_settings.dart';

/// Vibration and tone are Android-only: iOS lets an app choose neither.
bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

/// Settings > Notifications: the phone's default sound, tone and vibration.
class AlertDefaultsSection extends ConsumerWidget {
  const AlertDefaultsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final defaults = ref.watch(alertPrefsProvider).value?.defaults;
    if (defaults == null) return const SizedBox.shrink();
    final controller = ref.read(alertPrefsProvider.notifier);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l.alertSoundAndVibration,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        SisSwitchTile(
          key: const ValueKey('alert-sound'),
          title: l.commonSound,
          subtitle: l.alertSoundHint,
          value: defaults.sound,
          onChanged: (on) =>
              controller.setDefaults(defaults.copyWith(sound: on)),
        ),
        if (_isAndroid)
          ListTile(
            key: const ValueKey('alert-tone'),
            title: Text(l.alertTone),
            subtitle: Text(defaults.toneName ?? l.alertToneDefault),
            enabled: defaults.sound,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: controller.pickTone,
          ),
        if (_isAndroid)
          SisSwitchTile(
            key: const ValueKey('alert-vibration'),
            title: l.commonVibration,
            subtitle: l.alertVibrationHint,
            value: defaults.vibration,
            onChanged: (on) =>
                controller.setDefaults(defaults.copyWith(vibration: on)),
          ),
      ],
    );
  }
}

/// On a chat's profile page: this chat's own sound and vibration, each
/// Default (follow the settings above), On or Off.
class ChatAlertTiles extends ConsumerWidget {
  const ChatAlertTiles({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final prefs = ref.watch(alertPrefsProvider).value;
    if (prefs == null) return const SizedBox.shrink();
    final chat = prefs.chat(conversationId);
    final controller = ref.read(alertPrefsProvider.notifier);
    return Column(
      children: [
        _ChoiceTile(
          tileKey: 'chat-alert-sound',
          title: l.commonSound,
          value: chat.sound,
          onChanged: (v) =>
              controller.setChat(conversationId, chat.copyWith(sound: v)),
        ),
        if (_isAndroid)
          _ChoiceTile(
            tileKey: 'chat-alert-vibration',
            title: l.commonVibration,
            value: chat.vibration,
            onChanged: (v) =>
                controller.setChat(conversationId, chat.copyWith(vibration: v)),
          ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.tileKey,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String tileKey;
  final String title;
  final AlertChoice value;
  final ValueChanged<AlertChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      key: ValueKey(tileKey),
      padding: SisTokens.settingsRowPadding,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
          ),
          DropdownButton<AlertChoice>(
            key: ValueKey('$tileKey-choice'),
            underline: const SizedBox.shrink(),
            value: value,
            items: [
              for (final c in AlertChoice.values)
                DropdownMenuItem(
                  value: c,
                  child: Text(switch (c) {
                    AlertChoice.byDefault => l.alertChoiceDefault,
                    AlertChoice.on => l.alertChoiceOn,
                    AlertChoice.off => l.alertChoiceOff,
                  }),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
