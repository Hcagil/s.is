import 'package:flutter/material.dart';

import '../domain/group_event.dart';

/// An admin-only line: "X left" / "X was removed" / "X was added". Read
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
    final subject = names[event.subjectId] ?? 'Someone';
    final text = switch (event.kind) {
      GroupEventKind.left => '$subject left',
      GroupEventKind.removed => '$subject was removed',
      GroupEventKind.added => '$subject was added',
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
