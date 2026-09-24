import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../chat/application/chat_controllers.dart';
import '../../chat/presentation/conversation_list.dart';
import '../application/notification_settings_controller.dart';
import '../domain/notification_settings.dart';

/// Whether and how the member is notified of new messages, and what is
/// muted.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> save(NotificationSettings next) async {
      final r = await ref
          .read(notificationSettingsProvider.notifier)
          .save(next);
      if (r case Err(:final failure) when context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failure.message)));
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: switch (ref.watch(notificationSettingsProvider)) {
        AsyncData(:final value) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            SwitchListTile(
              key: const ValueKey('notif-enabled'),
              title: const Text('Notifications'),
              subtitle: const Text('New messages when the app is closed'),
              value: value.enabled,
              onChanged: (on) => save(value.copyWith(enabled: on)),
            ),
            const _Header('On the lock screen'),
            RadioGroup<NotificationPreview>(
              groupValue: value.preview,
              onChanged: (p) {
                if (p != null) save(value.copyWith(preview: p));
              },
              child: Column(
                children: [
                  for (final p in NotificationPreview.values)
                    RadioListTile<NotificationPreview>(
                      key: ValueKey('notif-preview-${p.name}'),
                      value: p,
                      title: Text(switch (p) {
                        NotificationPreview.full => 'Name and message',
                        NotificationPreview.sender => 'Only who it is from',
                        NotificationPreview.none => 'No details',
                      }),
                      subtitle: Text(switch (p) {
                        NotificationPreview.full => 'Ayşe: See you at 8',
                        NotificationPreview.sender => 'Ayşe: New message',
                        NotificationPreview.none => 'SIS: New message',
                      }),
                    ),
                ],
              ),
            ),
            const _Header('Muted'),
            const _MutedList(),
          ],
        ),
        AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(reasonOf(error), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () =>
                      ref.read(notificationSettingsProvider.notifier).retry(),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// A small section title, styled like the rest of the settings pages.
class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Every conversation and person currently muted, with a way to unmute.
class _MutedList extends ConsumerWidget {
  const _MutedList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(mutesProvider)) {
      AsyncData(:final value) => _buildActive(context, ref, value),
      AsyncError(:final error) => ListTile(title: Text(reasonOf(error))),
      _ => const LinearProgressIndicator(),
    };
  }

  Widget _buildActive(BuildContext context, WidgetRef ref, List<Mute> mutes) {
    final now = DateTime.now();
    final active = mutes.where((m) => m.activeAt(now)).toList();
    if (active.isEmpty) {
      return const ListTile(title: Text('Nothing is muted'), enabled: false);
    }
    final members = ref.watch(membersProvider).value ?? const [];
    final conversations = ref.watch(conversationListProvider).value ?? const [];

    Future<void> unmute(MuteKind kind, String target) async {
      final r = await ref.read(mutesProvider.notifier).unmute(kind, target);
      if (r case Err(:final failure) when context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failure.message)));
      }
    }

    return Column(
      children: [
        for (final m in active)
          ListTile(
            leading: Icon(
              m.kind == MuteKind.person
                  ? Icons.person_outline
                  : Icons.chat_bubble_outline,
            ),
            title: Text(switch (m.kind) {
              MuteKind.person =>
                members
                        .where((mem) => mem.userId == m.target)
                        .firstOrNull
                        ?.displayName ??
                    'Someone',
              MuteKind.conversation =>
                conversations
                        .where((c) => c.id == m.target)
                        .firstOrNull
                        ?.label ??
                    'A chat',
            }),
            subtitle: Text(muteLabel(m.until, now)),
            trailing: TextButton(
              key: ValueKey('unmute-${m.kind.name}-${m.target}'),
              onPressed: () => unmute(m.kind, m.target),
              child: const Text('Unmute'),
            ),
          ),
      ],
    );
  }
}

/// Shows and changes whether one conversation or person is muted. Tapping it
/// opens a sheet to pick a length, or to unmute.
class MuteTile extends ConsumerWidget {
  const MuteTile({super.key, required this.kind, required this.target});

  final MuteKind kind;
  final String target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mutes = ref.watch(mutesProvider).value ?? const <Mute>[];
    final active = activeMute(mutes, kind, target, DateTime.now());
    return ListTile(
      key: const ValueKey('mute-tile'),
      leading: Icon(
        active == null
            ? Icons.notifications_outlined
            : Icons.notifications_off_outlined,
      ),
      title: Text(active == null ? 'Mute notifications' : 'Muted'),
      subtitle: active == null
          ? null
          : Text(muteLabel(active.until, DateTime.now())),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in MuteLength.values)
                ListTile(
                  key: ValueKey('mute-${l.name}'),
                  title: Text(l.label),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final r = await ref
                        .read(mutesProvider.notifier)
                        .mute(kind, target, l);
                    if (r case Err(:final failure) when context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(failure.message)));
                    }
                  },
                ),
              if (active != null)
                ListTile(
                  key: const ValueKey('mute-off'),
                  title: const Text('Unmute'),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final r = await ref
                        .read(mutesProvider.notifier)
                        .unmute(kind, target);
                    if (r case Err(:final failure) when context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(failure.message)));
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
