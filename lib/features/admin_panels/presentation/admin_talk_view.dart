import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/conversation_tile.dart' show FadeDivider;
import '../application/admin_panels_controller.dart';
import 'admin_conversation_view.dart';
import 'admin_talk_composer.dart';

class AdminTalkView extends ConsumerStatefulWidget {
  const AdminTalkView({super.key});

  @override
  ConsumerState<AdminTalkView> createState() => _AdminTalkViewState();
}

class _AdminTalkViewState extends ConsumerState<AdminTalkView> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(adminPanelsProvider);
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    if (!s.hasSnapshot) {
      return const Align(
        alignment: Alignment.topCenter,
        child: SisProgressLine(),
      );
    }

    final convs = s.snapshot.conversations;

    if (_open != null) {
      final c = convs.where((c) => c.id == _open).firstOrNull;
      return AdminConversationView(
        key: ValueKey('admin-conv-$_open'),
        conv: _open!,
        topic: c?.topic ?? '',
        onBack: () => setState(() => _open = null),
      );
    }

    return Column(
      children: [
        Expanded(
          child: convs.isEmpty
              ? Center(child: Text(l.adminTalkEmpty))
              : ListView(
                  children: [
                    for (final c in convs)
                      Column(
                        key: ValueKey('admin-conv-tile-${c.id}'),
                        children: [
                          SisSettingsRow(
                            icon: c.unread
                                ? Icons.mark_chat_unread_outlined
                                : Icons.chat_bubble_outline_rounded,
                            iconColor: c.unread ? t.brand : null,
                            title: c.topic,
                            value: c.waiting > 0 ? '${c.waiting}' : null,
                            onTap: () => setState(() => _open = c.id),
                          ),
                          const FadeDivider(),
                        ],
                      ),
                  ],
                ),
        ),
        const AdminTalkComposer(),
      ],
    );
  }
}
