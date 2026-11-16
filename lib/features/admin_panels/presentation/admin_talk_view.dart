import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/conversation_tile.dart' show FadeDivider;
import '../application/admin_panels_controller.dart';
import '../domain/admin_models.dart';
import 'admin_conversation_view.dart';
import 'admin_talk_composer.dart';
import 'admin_answer_status.dart';

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
      if (c != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(
              ref
                  .read(adminPanelsProvider.notifier)
                  .markConversationRead(c, c.mat),
            );
          }
        });
      }
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _open = null);
        },
        child: AdminConversationView(
          key: ValueKey('admin-conv-$_open'),
          conv: _open!,
          topic: c?.topic ?? '',
          onBack: () => setState(() => _open = null),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: convs.isEmpty
              ? Center(child: Text(l.adminTalkEmpty))
              : ListView(
                  children: [
                    for (final c in s.talkOrder)
                      Column(
                        key: ValueKey('admin-conv-tile-${c.id}'),
                        children: [
                          GestureDetector(
                            onLongPress: () => _openPinMenu(c, s.isPinned(c)),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SisSettingsRow(
                                    icon: c.isUnread(s.readUpto[c.id] ?? 0)
                                        ? Icons.mark_chat_unread_outlined
                                        : Icons.chat_bubble_outline_rounded,
                                    iconColor: c.isUnread(s.readUpto[c.id] ?? 0)
                                        ? t.brand
                                        : null,
                                    title: c.topic,
                                    value: c.waiting > 0
                                        ? '${c.waiting}'
                                        : null,
                                    onTap: () {
                                      unawaited(
                                        ref
                                            .read(adminPanelsProvider.notifier)
                                            .markConversationRead(c, c.mat),
                                      );
                                      setState(() => _open = c.id);
                                    },
                                  ),
                                ),
                                if (s.isPinned(c))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 16),
                                    child: Icon(
                                      Icons.push_pin,
                                      key: ValueKey(
                                        'admin-conv-pinmark-${c.id}',
                                      ),
                                      size: 16,
                                      color: t.muted,
                                      semanticLabel: l.adminTalkPinned,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const FadeDivider(),
                        ],
                      ),
                  ],
                ),
        ),
        if (s.latestAnswer('talk') case final a?)
          AdminAnswerStatusLine(answer: a),
        const AdminTalkComposer(),
      ],
    );
  }

  Future<void> _openPinMenu(AdminConversation c, bool pinned) async {
    final l = AppLocalizations.of(context);
    final choose = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListTile(
          key: ValueKey('admin-conv-pin-${c.id}'),
          leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
          title: Text(pinned ? l.adminTalkUnpin : l.adminTalkPin),
          onTap: () => Navigator.of(ctx).pop(!pinned),
        ),
      ),
    );
    if (choose == null || !mounted) return;
    final f = await ref
        .read(adminPanelsProvider.notifier)
        .setConversationPinned(c.id, choose);
    if (f != null && mounted) {
      showSisNotice(
        context,
        choose ? l.adminTalkPinFailed : l.adminTalkUnpinFailed,
        isError: true,
      );
    }
  }
}
