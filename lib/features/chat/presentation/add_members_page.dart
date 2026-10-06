import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import 'picker_widgets.dart';

/// Opens the add-members page for a group. [current] are the user ids already
/// in it; [groupTitle] is shown under the page title.
Future<void> showAddMembersPage(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  required Set<String> current,
  required String groupTitle,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => AddMembersPage(
      conversationId,
      current: current,
      groupTitle: groupTitle,
    ),
  ),
);

/// Full-screen add-members page (admins only): search, ticked people as chips,
/// the "Show old messages?" switch and an Add button.
class AddMembersPage extends ConsumerStatefulWidget {
  /// Creates the page for [conversationId].
  const AddMembersPage(
    this.conversationId, {
    super.key,
    required this.current,
    required this.groupTitle,
  });

  /// The group being added to.
  final String conversationId;

  /// User ids already in the group.
  final Set<String> current;

  /// The group's name, for the app bar.
  final String groupTitle;

  @override
  ConsumerState<AddMembersPage> createState() => _AddMembersPageState();
}

class _AddMembersPageState extends ConsumerState<AddMembersPage> {
  final _search = TextEditingController();
  final _chosen = <Member>[];
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _isChosen(Member m) => _chosen.any((c) => c.userId == m.userId);

  void _toggle(Member m) => setState(() {
    if (_isChosen(m)) {
      _chosen.removeWhere((c) => c.userId == m.userId);
    } else {
      _chosen.add(m);
    }
  });

  Future<void> _add() async {
    setState(() => _busy = true);
    final result = await ref.read(groupControllerProvider).addMembers(
      widget.conversationId,
      [for (final m in _chosen) m.userId],
      withHistory: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Ok():
        showSisNotice(context, AppLocalizations.of(context).addMembersDone);
        Navigator.of(context).pop();
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final choices = ref
        .watch(yourPeopleProvider)
        .whenData(
          (all) => [
            for (final m in all)
              if (!widget.current.contains(m.userId)) m,
          ],
        )
        .value;
    return Scaffold(
      key: const ValueKey('add-members-page'),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.commonAddMembers),
            Text(
              widget.groupTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          PickerSearchField(
            fieldKey: const ValueKey('add-members-search'),
            controller: _search,
            hint: l.commonSearchPeople,
            onChanged: (_) => setState(() {}),
          ),
          PickedChips(
            keyPrefix: 'add-chip',
            people: _chosen,
            onRemove: _toggle,
          ),
          Expanded(
            child: choices == null
                ? const Center(child: SisLoadingLogo(size: 40))
                : choices.isEmpty
                ? Center(
                    key: const ValueKey('add-members-empty'),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l.addMembersNoneTitle,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l.addMembersNoneBody,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final m in choices)
                        if (matchesPerson(m, _search.text))
                          PersonPickTile(
                            key: ValueKey('add-member-${m.userId}'),
                            person: m,
                            selected: _isChosen(m),
                            onTap: () => _toggle(m),
                          ),
                      if (!choices.any((m) => matchesPerson(m, _search.text)))
                        ListTile(title: Text(l.commonNobodyFound)),
                    ],
                  ),
          ),
          if (choices != null && choices.isNotEmpty)
            PickerBottomBar(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('add-members-confirm'),
                      onPressed: _chosen.isEmpty || _busy ? null : _add,
                      child: Text(
                        _busy
                            ? l.addMembersAdding
                            : _chosen.isEmpty
                            ? l.addMembersAdd
                            : l.addMembersAddCount(_chosen.length),
                      ),
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
