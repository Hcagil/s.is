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
import 'member_name.dart';
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
    Ok() =>
      total == 1
          ? AppLocalizations.of(context).commonForwarded
          : AppLocalizations.of(context).forwardDoneMany(total),
    Err(:final failure) => failure.message,
  }, isError: r is Err);
}

/// Up to three overlapping avatars of the ticked targets, left of Send.
class _ChosenStack extends StatelessWidget {
  const _ChosenStack({required this.chosen});

  final List<({String label, String seed, String? avatarPath})> chosen;

  @override
  Widget build(BuildContext context) {
    if (chosen.isEmpty) return const SizedBox.shrink();
    final shown = chosen.take(3).toList();
    final ring = SisBrand.of(context).background;
    return SizedBox(
      key: const ValueKey('forward-chosen'),
      width: 28.0 + (shown.length - 1) * 16,
      height: 28,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 16.0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ring, width: 2),
                ),
                child: PersonAvatar(
                  label: shown[i].label,
                  seed: shown[i].seed,
                  radius: 12,
                  avatarPath: shown[i].avatarPath,
                ),
              ),
            ),
        ],
      ),
    );
  }
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
        // The source chat is never a target; the picker stays as it was.
        if (chat.id != widget.exclude) _chats.add(chat.id);
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
    final l = AppLocalizations.of(context);
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
            (query.isEmpty ||
                conversationLabel(l, c).toLowerCase().contains(query)))
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
        : widget.message.file != null
        ? widget.message.file!.name
        : widget.message.hasAttachment
        ? l.attachPhoto
        : l.commonMessage;
    final n = _chats.length + _people.length;
    final chosen = <({String label, String seed, String? avatarPath})>[
      for (final c in all)
        if (_chats.contains(c.id))
          (
            label: conversationLabel(l, c),
            seed: c.other?.userId ?? c.id,
            avatarPath: c.avatarPath ?? c.other?.avatarPath,
          ),
      for (final m in people)
        if (_people.contains(m.userId))
          (label: m.displayName, seed: m.userId, avatarPath: m.avatarPath),
    ];
    final header = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: scheme.onSurfaceVariant);

    return Scaffold(
      key: const ValueKey('forward-page'),
      appBar: AppBar(title: Text(l.forwardTitle)),
      body: Column(
        children: [
          PickerSearchField(
            fieldKey: const ValueKey('forward-search'),
            controller: _search,
            hint: l.forwardSearch,
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
                            text: l.forwardPrefix,
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
                      label: conversationLabel(l, c),
                      seed: c.other?.userId ?? c.id,
                      avatarPath: c.avatarPath ?? c.other?.avatarPath,
                    ),
                    title: Text(conversationLabel(l, c)),
                    subtitle: c.isGroup
                        ? Text(l.commonGroup)
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
                    child: Text(l.forwardPeople, style: header),
                  ),
                for (final m in newPeople)
                  PersonPickTile(
                    key: ValueKey('forward-person-${m.userId}'),
                    person: m,
                    selected: _people.contains(m.userId),
                    onTap: () => _toggle(_people, m.userId),
                  ),
                if (chats.isEmpty && newPeople.isEmpty && query.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      key: const ValueKey('forward-empty'),
                      child: Text(l.forwardNothing),
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
                Row(
                  children: [
                    _ChosenStack(chosen: chosen),
                    if (chosen.isNotEmpty) const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('forward-send'),
                        onPressed: n == 0
                            ? null
                            : () => Navigator.of(context).pop((
                                chatIds: _chats.toList(),
                                personIds: _people.toList(),
                              )),
                        child: Text(
                          n == 0 ? l.commonSend : l.forwardSendCount(n),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
