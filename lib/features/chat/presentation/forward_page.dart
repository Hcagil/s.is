import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/grey_option.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import 'new_chat_page.dart';
import 'person_avatar.dart';
import 'picker_widgets.dart';

/// Opens the forward page for [message], then forwards it to everything the
/// member ticked. People without a chat yet get one created on send.
Future<void> showForwardPage(
  BuildContext context,
  WidgetRef ref,
  Message message,
) async {
  final chosen = await Navigator.of(context)
      .push<({List<String> chatIds, List<String> personIds})>(
        MaterialPageRoute(
          builder: (_) => ForwardPage(
            message: message,
            exclude: ref.read(openConversationProvider),
          ),
        ),
      );
  if (chosen == null ||
      (chosen.chatIds.isEmpty && chosen.personIds.isEmpty) ||
      !context.mounted) {
    return;
  }
  final r = await ref
      .read(messagesProvider.notifier)
      .forwardTo(
        message,
        conversationIds: chosen.chatIds,
        personIds: chosen.personIds,
      );
  if (!context.mounted) return;
  final total = chosen.chatIds.length + chosen.personIds.length;
  showSisNotice(context, switch (r) {
    Ok() => total == 1 ? 'Forwarded' : 'Forwarded to $total chats',
    Err(:final failure) => failure.message,
  }, isError: r is Err);
}

/// Full-screen forward target picker: search, a "Forwarding" strip, chats and
/// people with no chat yet, multi-tick, one full-width Send button. Pops
/// `(chatIds, personIds)`, or null on back.
class ForwardPage extends ConsumerStatefulWidget {
  /// Creates the page for [message]; [exclude] is the open chat, left out.
  const ForwardPage({super.key, required this.message, required this.exclude});

  /// The message being forwarded.
  final Message message;

  /// The conversation currently open, which is not offered as a target.
  final String? exclude;

  @override
  ConsumerState<ForwardPage> createState() => _ForwardPageState();
}

class _ForwardPageState extends ConsumerState<ForwardPage> {
  final _search = TextEditingController();
  final _chats = <String>{};
  final _people = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The "New chat" row: pick a person on the new-chat page and tick them as a target. Someone who already has a chat ticks that chat instead.
  Future<void> _newChat() async {
    final m = await showNewChatPage(context);
    if (m == null || !mounted) return;
    final chat = (ref.read(conversationListProvider).value ?? const [])
        .where((c) => !c.isGroup && c.other?.userId == m.userId)
        .firstOrNull;
    setState(() {
      if (chat != null) {
        _chats.add(chat.id);
      } else {
        _people.add(m.userId);
      }
    });
  }

  void _toggle(Set<String> set, String id) => setState(() {
    if (!set.remove(id)) set.add(id);
  });

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final scheme = Theme.of(context).colorScheme;
    final query = _search.text.trim().toLowerCase();
    final all = ref.watch(conversationListProvider).value ?? const [];
    final people = ref.watch(yourPeopleProvider).value ?? const <Member>[];

    final chats = [
      for (final c in all)
        if (!c.isSystem &&
            !c.hasLeft &&
            c.id != widget.exclude &&
            (query.isEmpty || c.label.toLowerCase().contains(query)))
          c,
    ];
    final withChat = {
      for (final c in all)
        if (!c.isGroup && c.other != null) c.other!.userId,
    };
    final newPeople = [
      for (final m in people)
        if (!withChat.contains(m.userId) && matchesPerson(m, query)) m,
    ];

    final body = widget.message.body.trim();
    final preview = body.isNotEmpty
        ? body
        : widget.message.hasAttachment
        ? 'Photo'
        : 'Message';
    final n = _chats.length + _people.length;
    final l = AppLocalizations.of(context);
    final header = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: scheme.onSurfaceVariant);

    return Scaffold(
      key: const ValueKey('forward-page'),
      appBar: AppBar(title: const Text('Forward to')),
      body: Column(
        children: [
          PickerSearchField(
            fieldKey: const ValueKey('forward-search'),
            controller: _search,
            hint: 'Search chats and people',
            onChanged: (_) => setState(() {}),
          ),
          Padding(
            key: const ValueKey('forward-strip'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: t.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.shortcut, size: 18, color: t.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Forwarding: ',
                            style: TextStyle(
                              color: t.muted,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextSpan(text: preview),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                ListTile(
                  key: const ValueKey('forward-new-chat'),
                  leading: CircleAvatar(
                    backgroundColor: t.brand,
                    foregroundColor: Colors.white,
                    child: const Icon(Icons.edit_outlined),
                  ),
                  title: Text(
                    l.pickerNewChat,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: _newChat,
                ),
                if (chats.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(l.pickerRecent, style: header),
                  ),
                for (final c in chats)
                  ListTile(
                    key: ValueKey('forward-${c.id}'),
                    leading: PersonAvatar(
                      label: c.label,
                      seed: c.other?.userId ?? c.id,
                      avatarPath: c.avatarPath ?? c.other?.avatarPath,
                    ),
                    title: Text(c.label),
                    subtitle: c.isGroup
                        ? const Text('Group')
                        : c.other?.tag != null
                        ? Text('@${c.other!.tag}')
                        : null,
                    trailing: Icon(
                      _chats.contains(c.id)
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked,
                      color: _chats.contains(c.id) ? t.brand : t.muted,
                    ),
                    onTap: () => _toggle(_chats, c.id),
                  ),
                if (newPeople.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('People', style: header),
                  ),
                for (final m in newPeople)
                  PersonPickTile(
                    key: ValueKey('forward-person-${m.userId}'),
                    person: m,
                    selected: _people.contains(m.userId),
                    onTap: () => _toggle(_people, m.userId),
                  ),
                if (chats.isEmpty && newPeople.isEmpty && query.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      key: ValueKey('forward-empty'),
                      child: Text('Nothing found'),
                    ),
                  ),
              ],
            ),
          ),
          PickerBottomBar(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GreyOption(
                  name: 'caption',
                  child: Container(
                    width: double.infinity,
                    height: 40,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: t.surfaceHigh,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      l.pickerAddCaption,
                      style: TextStyle(color: t.muted, fontSize: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('forward-send'),
                    onPressed: n == 0
                        ? null
                        : () => Navigator.of(context).pop((
                            chatIds: _chats.toList(),
                            personIds: _people.toList(),
                          )),
                    child: Text(n == 0 ? 'Send' : 'Send ($n)'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
