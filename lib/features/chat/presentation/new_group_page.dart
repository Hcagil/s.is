import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import 'conversation_list.dart';
import 'picker_widgets.dart';

/// Opens the new-group page; returns the name and members, or null on back.
Future<({String title, List<Member> members})?> showNewGroupPage(
  BuildContext context,
) => Navigator.of(context).push<({String title, List<Member> members})>(
  MaterialPageRoute(builder: (_) => const NewGroupPage()),
);

/// Full-screen new group: name, search plus chips, Create group. Needs a name
/// and at least one person, so the button stays disabled rather than letting
/// the server refuse the call.
class NewGroupPage extends ConsumerStatefulWidget {
  /// Creates the page.
  const NewGroupPage({super.key});

  @override
  ConsumerState<NewGroupPage> createState() => _NewGroupPageState();
}

class _NewGroupPageState extends ConsumerState<NewGroupPage> {
  final _title = TextEditingController();
  final _search = TextEditingController();
  final _chosen = <Member>[];

  @override
  void dispose() {
    _title.dispose();
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

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(yourPeopleProvider);
    final ready = _title.text.trim().isNotEmpty && _chosen.isNotEmpty;
    final header = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      key: const ValueKey('new-group-page'),
      appBar: AppBar(title: const Text('New group')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const ValueKey('group-title'),
              controller: _title,
              textCapitalization: TextCapitalization.words,
              maxLength: 80,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Group name',
                counterText: '',
              ),
            ),
          ),
          PickerSearchField(
            fieldKey: const ValueKey('group-search'),
            controller: _search,
            hint: 'Search your people',
            onChanged: (_) => setState(() {}),
          ),
          PickedChips(
            keyPrefix: 'group-chip',
            people: _chosen,
            onRemove: _toggle,
          ),
          Expanded(
            child: switch (members) {
              AsyncData(:final value) when value.isEmpty => const ListTile(
                title: Text('Nobody else has signed in yet'),
              ),
              AsyncData(:final value) => ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text('Your people', style: header),
                  ),
                  for (final m in value)
                    if (matchesPerson(m, _search.text))
                      PersonPickTile(
                        key: ValueKey('group-member-${m.userId}'),
                        person: m,
                        selected: _isChosen(m),
                        onTap: () => _toggle(m),
                      ),
                  if (!value.any((m) => matchesPerson(m, _search.text)))
                    const ListTile(title: Text('Nobody found')),
                ],
              ),
              AsyncError(:final error) => ListTile(
                title: Text(reasonOf(error)),
              ),
              _ => const Center(child: SisLoadingLogo(size: 40)),
            },
          ),
          PickerBottomBar(
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('group-create'),
                onPressed: ready
                    ? () => Navigator.of(context).pop((
                        title: _title.text.trim(),
                        members: List<Member>.of(_chosen),
                      ))
                    : null,
                child: const Text('Create group'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
