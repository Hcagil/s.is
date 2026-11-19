import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/settings_row.dart';
import '../../../l10n/app_localizations.dart';
import '../application/notification_settings_controller.dart';
import '../domain/notification_settings.dart';
import './alert_widgets.dart';
import './notification_pages.dart';

class ChatSettingsRow extends StatelessWidget {
  const ChatSettingsRow({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    return SisSettingsRow(
      key: const ValueKey('chat-settings-row'),
      icon: Icons.tune_rounded,
      title: AppLocalizations.of(context).chatSettingsTitle,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatSettingsPage(conversationId: conversationId),
        ),
      ),
    );
  }
}

class ChatSettingsPage extends ConsumerWidget {
  const ChatSettingsPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final mutes = ref.watch(mutesProvider).value ?? const <Mute>[];
    final muted =
        activeMute(
          mutes,
          MuteKind.conversation,
          conversationId,
          DateTime.now(),
        ) !=
        null;
    return Scaffold(
      appBar: AppBar(title: Text(l.chatSettingsTitle)),
      body: ListView(
        children: [
          MuteTile(kind: MuteKind.conversation, target: conversationId),
          ChatAlertTiles(conversationId: conversationId, muted: muted),
        ],
      ),
    );
  }
}
