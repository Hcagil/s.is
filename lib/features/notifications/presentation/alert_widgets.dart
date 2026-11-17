import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../../../app/notice.dart';
import '../../../app/settings_row.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/alert_controller.dart';
import '../domain/alert_settings.dart';
import './alert_choice_sheet.dart';

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
  const ChatAlertTiles({
    super.key,
    required this.conversationId,
    this.muted = false,
  });

  final String conversationId;

  /// muted greys the rows and shows why; the saved choices stay.
  final bool muted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final prefs = ref.watch(alertPrefsProvider).value;
    if (prefs == null) return const SizedBox.shrink();
    final chat = prefs.chat(conversationId);
    return Column(
      children: [
        Opacity(
          opacity: muted ? 0.4 : 1,
          child: Column(
            children: [
              _row(
                context,
                ref,
                key: 'chat-alert-sound',
                icon: Icons.music_note_outlined,
                title: l.commonSound,
                value: chat.sound,
                onPicked: (v) => chat.copyWith(sound: v),
              ),
              if (_isAndroid)
                _row(
                  context,
                  ref,
                  key: 'chat-alert-vibration',
                  icon: Icons.vibration,
                  title: l.commonVibration,
                  value: chat.vibration,
                  onPicked: (v) => chat.copyWith(vibration: v),
                ),
            ],
          ),
        ),
        if (muted)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              _isAndroid ? l.chatMutedSoundVibrationNote : l.chatMutedSoundNote,
              key: const ValueKey('chat-alert-muted-note'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref, {
    required String key,
    required IconData icon,
    required String title,
    required AlertChoice value,
    required ChatAlert Function(AlertChoice) onPicked,
  }) {
    final l = AppLocalizations.of(context);
    return SisSettingsRow(
      key: ValueKey(key),
      icon: icon,
      title: title,
      value: label(l, value),
      onTap: muted
          ? null
          : () async {
              final picked = await showAlertChoiceSheet(
                context,
                title: title,
                current: value,
              );
              if (picked == null || picked == value) return;
              final r = await ref
                  .read(alertPrefsProvider.notifier)
                  .setChat(conversationId, onPicked(picked));
              if (r case Err(:final failure) when context.mounted) {
                showSisNotice(context, failure.message, isError: true);
              }
            },
    );
  }

  String label(AppLocalizations l, AlertChoice c) => switch (c) {
    AlertChoice.byDefault => l.alertChoiceDefault,
    AlertChoice.on => l.alertChoiceOn,
    AlertChoice.off => l.alertChoiceOff,
  };
}
