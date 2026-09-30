import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../application/alert_controller.dart';
import '../domain/alert_settings.dart';

/// Vibration and tone are Android-only: iOS lets an app choose neither.
bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

/// Settings > Notifications: the phone's default sound, tone and vibration.
class AlertDefaultsSection extends ConsumerWidget {
  const AlertDefaultsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              'Sound and vibration',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        SisSwitchTile(
          key: const ValueKey('alert-sound'),
          title: 'Sound',
          subtitle: 'Play a sound for new messages',
          value: defaults.sound,
          onChanged: (on) =>
              controller.setDefaults(defaults.copyWith(sound: on)),
        ),
        if (_isAndroid)
          ListTile(
            key: const ValueKey('alert-tone'),
            title: const Text('Tone'),
            subtitle: Text(defaults.toneName ?? 'System default'),
            enabled: defaults.sound,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: controller.pickTone,
          ),
        if (_isAndroid)
          SisSwitchTile(
            key: const ValueKey('alert-vibration'),
            title: 'Vibration',
            subtitle: 'Vibrate for new messages',
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
    final prefs = ref.watch(alertPrefsProvider).value;
    if (prefs == null) return const SizedBox.shrink();
    final chat = prefs.chat(conversationId);
    final controller = ref.read(alertPrefsProvider.notifier);
    return Column(
      children: [
        _ChoiceTile(
          tileKey: 'chat-alert-sound',
          title: 'Sound',
          value: chat.sound,
          onChanged: (v) =>
              controller.setChat(conversationId, chat.copyWith(sound: v)),
        ),
        if (_isAndroid)
          _ChoiceTile(
            tileKey: 'chat-alert-vibration',
            title: 'Vibration',
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
  Widget build(BuildContext context) => ListTile(
    key: ValueKey(tileKey),
    title: Text(title),
    trailing: DropdownButton<AlertChoice>(
      key: ValueKey('$tileKey-choice'),
      underline: const SizedBox.shrink(),
      value: value,
      items: [
        for (final c in AlertChoice.values)
          DropdownMenuItem(
            value: c,
            child: Text(switch (c) {
              AlertChoice.byDefault => 'Default',
              AlertChoice.on => 'On',
              AlertChoice.off => 'Off',
            }),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );
}
