import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/group_event.dart';

/// A group line: "X left" / "X was removed" / "X was added" (admins only) or
/// "X changed the group picture" (everyone). Read
/// from group_events (chatTimelineProvider), which the server already
/// scopes to a current admin -- nothing here decides visibility itself.
///
/// Names are resolved by the caller from the group's own roster (not
/// yourPeopleProvider): the subject of an event is exactly someone who
/// just left/was removed/was added, so they are usually NOT in the
/// current user's contact list.
class GroupEventLine extends StatelessWidget {
  const GroupEventLine(this.event, {required this.names, super.key});

  final GroupEvent event;

  /// userId -> displayName, from the group's roster.
  final Map<String, String> names;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final subject = names[event.subjectId] ?? l.commonSomeone;
    final text = switch (event.kind) {
      GroupEventKind.left => l.eventLeft(subject),
      GroupEventKind.removed => l.eventRemoved(subject),
      GroupEventKind.added => l.eventAdded(subject),
      GroupEventKind.picture => l.eventPictureChanged(subject),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
