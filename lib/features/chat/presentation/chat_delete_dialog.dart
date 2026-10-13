import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/conversation.dart';
import 'member_name.dart';
import 'person_avatar.dart';

Future<bool?> showDeleteChatsDialog(
  BuildContext context,
  List<Conversation> chats,
) {
  return showDialog<bool>(
    context: context,
    builder: (context) => _DeleteChatsDialog(chats: chats),
  );
}

class _DeleteChatsDialog extends StatefulWidget {
  const _DeleteChatsDialog({required this.chats});

  final List<Conversation> chats;

  @override
  State<_DeleteChatsDialog> createState() => _DeleteChatsDialogState();
}

class _DeleteChatsDialogState extends State<_DeleteChatsDialog> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    final chats = widget.chats;

    final titleWidget = _buildTitle(context, chats, l);
    final bodyWidget = _buildBody(chats, l);
    final checkboxWidget = _buildCheckbox(chats, l);
    final okLabel = _buildOkLabel(chats, l);

    return Dialog(
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: t.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleWidget,
              const SizedBox(height: 16),
              bodyWidget,
              if (checkboxWidget != null) ...[
                const SizedBox(height: 16),
                checkboxWidget,
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('delete-chat-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      l.chatDeleteCancel,
                      style: TextStyle(
                        color: t.brand,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('delete-chat-ok'),
                    onPressed: () => Navigator.of(context).pop(_checked),
                    child: Text(
                      okLabel,
                      style: TextStyle(
                        color: t.danger,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(
    BuildContext context,
    List<Conversation> chats,
    AppLocalizations l,
  ) {
    final t = SisBrand.of(context);
    if (chats.length > 1) {
      return Text(
        l.chatDeleteFewTitle(chats.length),
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: t.text,
        ),
      );
    }

    final c = chats.first;
    if (!c.isGroup) {
      return Row(
        children: [
          PersonAvatar(
            label: conversationLabel(l, c),
            seed: c.other?.userId ?? c.id,
            radius: 18,
            avatarPath: c.avatarPath ?? c.other?.avatarPath,
          ),
          const SizedBox(width: 12),
          Text(
            l.chatDeleteChat,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: t.text,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        PersonAvatar(
          label: conversationLabel(l, c),
          seed: c.id,
          radius: 18,
          avatarPath: c.avatarPath,
        ),
        const SizedBox(width: 12),
        Text(
          l.chatLeaveGroupTitle,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: t.text,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(List<Conversation> chats, AppLocalizations l) {
    final t = SisBrand.of(context);
    final text = chats.length > 1
        ? l.chatDeleteFewSure
        : chats.first.isGroup
        ? l.chatDeleteLeaveSure(conversationLabel(l, chats.first))
        : l.chatDeleteSure(conversationLabel(l, chats.first));

    return Text.rich(
      _bold(text, TextStyle(fontSize: 15, color: t.text)),
      textAlign: TextAlign.start,
    );
  }

  Widget? _buildCheckbox(List<Conversation> chats, AppLocalizations l) {
    if (chats.length > 1) {
      final hasOneToOne = chats.any((c) => !c.isGroup);
      if (!hasOneToOne) return null;

      return _buildCheckboxRow(l.chatDeleteBothSides);
    }

    final c = chats.first;
    if (c.isGroup && c.isAdmin) {
      return _buildCheckboxRow(l.chatDeleteGroupForAll);
    } else if (!c.isGroup) {
      final firstWord =
          c.other?.displayName.split(' ').firstOrNull ??
          conversationLabel(l, c);
      return _buildCheckboxRow(l.chatDeleteAlso(firstWord));
    }

    return null;
  }

  Widget _buildCheckboxRow(String label) {
    final t = SisBrand.of(context);
    return InkWell(
      key: const ValueKey('delete-chat-check'),
      onTap: () => setState(() {
        _checked = !_checked;
      }),
      child: Row(
        children: [
          Checkbox(
            value: _checked,
            onChanged: (v) => setState(() {
              _checked = v ?? false;
            }),
            activeColor: t.brand,
          ),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 15, color: t.text)),
          ),
        ],
      ),
    );
  }

  String _buildOkLabel(List<Conversation> chats, AppLocalizations l) {
    if (chats.length > 1) return l.chatDeleteAction;
    return l.chatDeleteChat;
  }

  TextSpan _bold(String s, TextStyle base) {
    final parts = s.split('**');
    final spans = <TextSpan>[];
    for (int i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      final style = i.isOdd ? base.copyWith(fontWeight: FontWeight.w700) : base;
      spans.add(TextSpan(text: parts[i], style: style));
    }
    return TextSpan(children: spans);
  }
}
