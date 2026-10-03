import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../auth/domain/member.dart';
import 'person_avatar.dart';

/// True when [m]'s name or tag contains [query], ignoring case, surrounding
/// spaces and a leading `@`. An empty query matches everyone.
bool matchesPerson(Member m, String query) {
  var q = query.trim().toLowerCase();
  if (q.startsWith('@')) q = q.substring(1);
  if (q.isEmpty) return true;
  return m.displayName.toLowerCase().contains(q) ||
      (m.tag?.toLowerCase().contains(q) ?? false);
}

/// The search box at the top of a picker page.
class PickerSearchField extends StatelessWidget {
  const PickerSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.fieldKey,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.prefixIcon = Icons.search,
    this.suffix,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  /// The key of the text field itself.
  final Key? fieldKey;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final IconData prefixIcon;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: TextField(
      key: fieldKey,
      controller: controller,
      autofocus: autofocus,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(prefixIcon),
        suffixIcon: suffix,
      ),
    ),
  );
}

/// The ticked people as a row of chips; tapping a chip unticks that person.
/// Each chip is keyed `<keyPrefix>-<userId>`.
class PickedChips extends StatelessWidget {
  const PickedChips({
    super.key,
    required this.people,
    required this.onRemove,
    required this.keyPrefix,
  });

  final List<Member> people;
  final void Function(Member) onRemove;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: people.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final m = people[i];
          return Center(
            child: InputChip(
              key: ValueKey('$keyPrefix-${m.userId}'),
              avatar: PersonAvatar(
                label: m.displayName,
                seed: m.userId,
                radius: 12,
                avatarPath: m.avatarPath,
              ),
              label: Text(m.displayName.split(' ').first),
              onPressed: () => onRemove(m),
              onDeleted: () => onRemove(m),
            ),
          );
        },
      ),
    );
  }
}

/// One person in a picker list: avatar, name, tag and a tick circle.
class PersonPickTile extends StatelessWidget {
  const PersonPickTile({
    super.key,
    required this.person,
    required this.selected,
    required this.onTap,
  });

  final Member person;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return ListTile(
      leading: PersonAvatar(
        label: person.displayName,
        seed: person.userId,
        avatarPath: person.avatarPath,
      ),
      title: Text(person.displayName),
      subtitle: person.tag == null ? null : Text('@${person.tag}'),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
        color: selected ? t.brand : t.muted,
      ),
      selected: selected,
      onTap: onTap,
    );
  }
}

/// The strip at the foot of a picker page that holds its one full-width
/// action button, clear of the system bar.
class PickerBottomBar extends StatelessWidget {
  const PickerBottomBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.background,
        border: Border(top: BorderSide(color: t.line)),
      ),
      child: SafeArea(
        top: false,
        // Its own Material: a ListTile or switch in the bar must not paint
        // under the coloured DecoratedBox.
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: child,
          ),
        ),
      ),
    );
  }
}
