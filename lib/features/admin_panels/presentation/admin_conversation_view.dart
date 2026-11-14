import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';
import 'admin_talk_composer.dart';
import 'admin_answer_status.dart';

class AdminConversationView extends ConsumerWidget {
  const AdminConversationView({
    super.key,
    required this.conv,
    required this.topic,
    required this.onBack,
  });

  final String conv;
  final String topic;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(adminPanelsProvider);
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    final msgs = s.snapshot.messages.where((m) => m.conv == conv).toList();

    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('admin-talk-back'),
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                topic,
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (s.snapshot.truncated)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              l.adminTalkTruncated,
              key: const ValueKey('admin-talk-truncated'),
              style: TextStyle(color: t.muted),
            ),
          ),
        Expanded(
          child: ListView(
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final m in msgs.reversed)
                _Bubble(
                  key: ValueKey('admin-msg-${m.id}'),
                  text: m.text,
                  mine: m.from == 'owner',
                ),
            ],
          ),
        ),
        if (s.latestAnswer('talk', id: conv) case final a?)
          AdminAnswerStatusLine(answer: a),
        AdminTalkComposer(key: ValueKey('admin-composer-$conv'), conv: conv),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({super.key, required this.text, required this.mine});

  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final bg = mine ? (t.mine ?? t.brand) : t.theirs;
    final fg = mine ? t.onMine : t.onTheirs;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text, style: TextStyle(color: fg)),
      ),
    );
  }
}
