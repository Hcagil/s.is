import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/settings_row.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/application/chat_controllers.dart';
import '../../chat/presentation/message_menu_card.dart';
import '../application/notification_settings_controller.dart';
import '../domain/notification_settings.dart';
import 'alert_widgets.dart';

/// Whether and how the member is notified of new messages, and what is
/// muted.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    Future<void> save(NotificationSettings next) async {
      final r = await ref
          .read(notificationSettingsProvider.notifier)
          .save(next);
      if (r case Err(:final failure) when context.mounted) {
        showSisNotice(context, failure.message, isError: true);
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.commonNotifications)),
      body: switch (ref.watch(notificationSettingsProvider)) {
        AsyncData(:final value) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            SisSwitchTile(
              key: const ValueKey('notif-enabled'),
              title: l.commonNotifications,
              subtitle: l.notifSwitchHint,
              value: value.enabled,
              onChanged: (on) => save(value.copyWith(enabled: on)),
            ),
            _Header(l.notifLockScreen),
            Column(
              children: [
                for (final p in NotificationPreview.values)
                  SisChoiceCard<NotificationPreview>(
                    key: ValueKey('notif-preview-${p.name}'),
                    value: p,
                    groupValue: value.preview,
                    onChanged: (p) => save(value.copyWith(preview: p)),
                    title: switch (p) {
                      NotificationPreview.full => l.notifPreviewFull,
                      NotificationPreview.sender => l.notifPreviewSender,
                      NotificationPreview.none => l.notifPreviewNone,
                    },
                    subtitle: switch (p) {
                      NotificationPreview.full => l.notifSampleFull,
                      NotificationPreview.sender => l.notifSampleSender,
                      NotificationPreview.none => l.notifSampleNone,
                    },
                  ),
              ],
            ),
            const AlertDefaultsSection(),
            _Header(l.chatMutedLabel),
            const _MutedList(),
          ],
        ),
        AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(failureReason(error), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () =>
                      ref.read(notificationSettingsProvider.notifier).retry(),
                  child: Text(l.commonTryAgain),
                ),
              ],
            ),
          ),
        ),
        _ => const Center(child: SisLoadingLogo()),
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
      AsyncError(:final error) => ListTile(title: Text(failureReason(error))),
      _ => const SisProgressLine(),
    };
  }

  Widget _buildActive(BuildContext context, WidgetRef ref, List<Mute> mutes) {
    final l = AppLocalizations.of(context);
    final now = DateTime.now();
    final active = mutes.where((m) => m.activeAt(now)).toList();
    if (active.isEmpty) {
      return ListTile(title: Text(l.notifNothingMuted), enabled: false);
    }
    final members = ref.watch(yourPeopleProvider).value ?? const [];
    final conversations = ref.watch(conversationListProvider).value ?? const [];

    Future<void> unmute(MuteKind kind, String target) async {
      final r = await ref.read(mutesProvider.notifier).unmute(kind, target);
      if (r case Err(:final failure) when context.mounted) {
        showSisNotice(context, failure.message, isError: true);
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
                    l.commonSomeone,
              MuteKind.conversation =>
                conversations
                        .where((c) => c.id == m.target)
                        .firstOrNull
                        ?.label ??
                    l.notifAChat,
            }),
            subtitle: Text(muteEndLabel(l, m.until, now)),
            trailing: TextButton(
              key: ValueKey('unmute-${m.kind.name}-${m.target}'),
              onPressed: () => unmute(m.kind, m.target),
              child: Text(l.chatMenuUnmute),
            ),
          ),
      ],
    );
  }
}

/// The localised name of a mute length, for every card that offers them.
String muteLengthLabel(AppLocalizations l, MuteLength length) =>
    switch (length) {
      MuteLength.oneHour => l.muteOneHour,
      MuteLength.eightHours => l.muteEightHours,
      MuteLength.oneDay => l.muteOneDay,
      MuteLength.threeDays => l.muteThreeDays,
      MuteLength.oneWeek => l.muteOneWeek,
    };

/// How a mute's end reads on screen, in the member's language.
String muteEndLabel(AppLocalizations l, DateTime? until, DateTime now) {
  final end = muteEnd(until, now);
  final at = end.at;
  if (at == null) return l.muteAlways;
  final time =
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
  return switch (end.day) {
    MuteDay.always => l.muteAlways,
    MuteDay.today => l.muteUntilToday(time),
    MuteDay.tomorrow => l.muteUntilTomorrow(time),
    MuteDay.later => l.muteUntilDate(at, time),
  };
}

/// Shows and changes whether one conversation or person is muted. Tapping it
/// opens a floating card below-right to pick a length, or to unmute; a tap on
/// a row applies it and closes the card.
class MuteTile extends ConsumerWidget {
  const MuteTile({super.key, required this.kind, required this.target});

  final MuteKind kind;
  final String target;

  Future<void> _open(BuildContext context, WidgetRef ref, Mute? active) async {
    final box = context.findRenderObject() as RenderBox;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final choice = await showMenuCard<String>(
      context,
      anchor: anchor,
      alignEnd: true,
      below: true,
      highlightAnchor: false,
      cardKey: const ValueKey('mute-card'),
      actions: [
        for (final l in MuteLength.values)
          MenuCardAction<String>(
            value: l.name,
            keyId: 'mute-${l.name}',
            rowKey: ValueKey('mute-${l.name}'),
            icon: l == MuteLength.oneWeek
                ? Icons.date_range_outlined
                : Icons.schedule_outlined,
            label: muteLengthLabel(AppLocalizations.of(context), l),
          ),
        if (active != null)
          MenuCardAction<String>(
            value: 'off',
            keyId: 'mute-off',
            rowKey: const ValueKey('mute-off'),
            icon: Icons.notifications_active_outlined,
            label: AppLocalizations.of(context).chatMenuUnmute,
          ),
      ],
    );
    if (choice == null || !context.mounted) return;
    final notifier = ref.read(mutesProvider.notifier);
    final r = choice == 'off'
        ? await notifier.unmute(kind, target)
        : await notifier.mute(kind, target, MuteLength.values.byName(choice));
    if (r case Err(:final failure) when context.mounted) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final mutes = ref.watch(mutesProvider).value ?? const <Mute>[];
    final active = activeMute(mutes, kind, target, DateTime.now());
    return SisSettingsRow(
      key: const ValueKey('mute-tile'),
      icon: active == null
          ? Icons.notifications_outlined
          : Icons.notifications_off_outlined,
      title: active == null ? l.notifMuteTitle : l.chatMutedLabel,
      value: active == null
          ? null
          : muteEndLabel(l, active.until, DateTime.now()),
      onTap: () => _open(context, ref, active),
    );
  }
}
