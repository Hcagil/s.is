import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/grey_option.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import 'person_avatar.dart';
import 'picker_widgets.dart';

/// Opens the new-chat page; returns the person chosen, or null on back.
Future<Member?> showNewChatPage(BuildContext context) =>
    Navigator.of(context)
        .push<Member>(MaterialPageRoute(builder: (_) => const NewChatPage()));

/// Full-screen new chat: exact-tag search on top, "your people" below. Pops
/// the chosen [Member].
class NewChatPage extends ConsumerStatefulWidget {
  /// Creates the page.
  const NewChatPage({super.key});

  @override
  ConsumerState<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends ConsumerState<NewChatPage> {
  final _tagField = TextEditingController();
  bool _searching = false;
  String? _searchError;
  Member? _found;
  bool _searchedEmpty = false;

  @override
  void dispose() {
    _tagField.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final tag = _tagField.text.trim();
    if (tag.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _found = null;
      _searchedEmpty = false;
    });
    final result = await ref
        .read(contactsControllerProvider.notifier)
        .findByTag(tag);
    if (!mounted) return;
    setState(() {
      _searching = false;
      switch (result) {
        case Ok(:final value) when value != null:
          _found = value;
        case Ok():
          _searchedEmpty = true;
        case Err(:final failure):
          _searchError = failure.message;
      }
    });
  }

  Future<void> _toggleContact(Member m, bool isContact) async {
    final notifier = ref.read(contactsControllerProvider.notifier);
    final result = isContact
        ? await notifier.remove(m.userId)
        : await notifier.add(m.userId);
    if (!mounted) return;
    if (result case Err(:final failure)) {
      showSisNotice(context, failure.message, isError: true);
    } else {
      final l = AppLocalizations.of(context);
      showSisNotice(context, isContact ? l.contactRemoved : l.contactAdded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final people = ref.watch(yourPeopleProvider);
    final contactIds =
        ref.watch(contactsControllerProvider).value ?? const <String>{};
    final header = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      key: const ValueKey('new-chat-page'),
      appBar: AppBar(title: Text(l.pickerNewChat)),
      body: Column(
        children: [
          PickerSearchField(
            fieldKey: const ValueKey('find-by-tag-field'),
            controller: _tagField,
            hint: l.newChatTagHint,
            prefixIcon: Icons.alternate_email_rounded,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            suffix: IconButton(
              key: const ValueKey('find-by-tag-submit'),
              icon: _searching
                  ? const SisLoadingLogo(size: 18)
                  : const Icon(Icons.search),
              onPressed: _searching ? null : _search,
            ),
          ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _searchError!,
                key: const ValueKey('find-by-tag-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_searchedEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l.newChatNoTag,
                key: const ValueKey('find-by-tag-empty'),
              ),
            ),
          if (_found case final found?) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l.newChatFound, style: header),
              ),
            ),
            ListTile(
              key: ValueKey('find-by-tag-result-${found.userId}'),
              leading: PersonAvatar(
                label: found.displayName,
                seed: found.userId,
                avatarPath: found.avatarPath,
              ),
              title: Text(found.displayName),
              subtitle: found.tag == null ? null : Text('@${found.tag}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: ValueKey('find-by-tag-toggle-${found.userId}'),
                    icon: Icon(
                      contactIds.contains(found.userId)
                          ? Icons.person_remove_outlined
                          : Icons.person_add_alt_1_outlined,
                    ),
                    tooltip: contactIds.contains(found.userId)
                        ? l.contactRemove
                        : l.contactAdd,
                    onPressed: () => _toggleContact(
                      found,
                      contactIds.contains(found.userId),
                    ),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    key: ValueKey('find-by-tag-chat-${found.userId}'),
                    onPressed: () => Navigator.of(context).pop(found),
                    child: Text(l.newChatChat),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 1),
          GreyOption(
            name: 'f_perm',
            label: AppLocalizations.of(context).findFromContacts,
            child: ListTile(
              leading: const Icon(Icons.contacts_outlined),
              title: Text(AppLocalizations.of(context).findFromContacts),
            ),
          ),
          Expanded(
            child: switch (people) {
              AsyncData(:final value) when value.isEmpty => ListTile(
                title: Text(l.newChatEmpty),
              ),
              AsyncData(:final value) => ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(l.commonYourPeople, style: header),
                  ),
                  for (final m in value)
                    ListTile(
                      key: ValueKey('member-${m.userId}'),
                      leading: PersonAvatar(
                        label: m.displayName,
                        seed: m.userId,
                        online: false,
                        dotKey: ValueKey('picker-online-${m.userId}'),
                        avatarPath: m.avatarPath,
                      ),
                      title: Text(m.displayName),
                      subtitle: m.tag == null ? null : Text('@${m.tag}'),
                      onTap: () => Navigator.of(context).pop(m),
                    ),
                ],
              ),
              AsyncError(:final error) => ListTile(
                title: Text(failureReason(error)),
              ),
              _ => const Center(child: SisLoadingLogo(size: 40)),
            },
          ),
        ],
      ),
    );
  }
}
