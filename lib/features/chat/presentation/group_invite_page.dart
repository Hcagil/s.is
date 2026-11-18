import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/grey_option.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/application/session_controller.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import '../application/invite_link_controller.dart';
import '../domain/invite_link.dart';
import 'invite_confirm_dialog.dart';
import 'invite_time_sheet.dart';
import 'invite_widgets.dart';

class GroupInvitePage extends ConsumerStatefulWidget {
  const GroupInvitePage({
    super.key,
    required this.conversationId,
    required this.title,
  });

  final String conversationId;
  final String title;

  @override
  ConsumerState<GroupInvitePage> createState() => _GroupInvitePageState();
}

/// Opens the page: the admin's "Invite link" page of a group.
Future<void> showGroupInvitePage(
  BuildContext context,
  String conversationId,
  String title,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) =>
        GroupInvitePage(conversationId: conversationId, title: title),
  ),
);

class _GroupInvitePageState extends ConsumerState<GroupInvitePage> {
  bool _busy = false;
  bool _offline = false;
  bool _failed = false;
  Future<void> Function()? _retry;
  int? get _days =>
      ref.read(inviteLinkProvider(widget.conversationId)).value?.validDays;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final id = widget.conversationId;
    final link = ref.watch(inviteLinkProvider(id));
    final count =
        ref
            .watch(groupRosterProvider(id))
            .value
            ?.where((m) => !m.hasLeft)
            .length ??
        0;
    final avatarPath = (ref.watch(conversationListProvider).value ?? const [])
        .where((c) => c.id == id)
        .firstOrNull
        ?.avatarPath;
    final current = link.value;

    final List<Widget> content;
    if (link.isLoading && !link.hasValue) {
      content = [Center(child: SisLoadingLogo(size: 40))];
    } else if (link.hasError && !link.hasValue) {
      final error = link.error;
      final isOffline = error is NetworkFailure && error.retryable;
      content = [
        if (isOffline) InviteRedBox(text: l.inviteNoInternet),
        if (isOffline)
          Text(l.groupInviteNoneOfflineBody, style: TextStyle(color: t.muted)),
        if (!isOffline)
          InviteRedBox(
            text: error is Failure ? error.message : l.groupInviteSaveFailed,
          ),
        OutlinedButton(
          key: const ValueKey('invite-load-retry'),
          onPressed: () => ref.invalidate(inviteLinkProvider(id)),
          child: Text(l.commonTryAgain),
        ),
      ];
    } else if (current == null) {
      content = [
        Text(
          l.groupInviteNoneTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(l.groupInviteNoneBody, style: TextStyle(color: t.muted)),
        if (_offline)
          InviteRedBox(text: l.inviteNoInternet, keyId: 'invite-offline-box'),
        if (_offline)
          Text(l.groupInviteNoneOfflineBody, style: TextStyle(color: t.muted)),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('invite-create'),
            onPressed: _busy ? null : _create,
            child: Text(l.groupInviteCreate),
          ),
        ),
      ];
    } else {
      final expired = current.expiredAt(DateTime.now());
      final text = inviteText(
        current.token,
        ref.read(runtimeConfigProvider).inviteLinkBase,
      );
      if (expired) {
        content = [
          InviteLinkBox(text: text, grey: true),
          Text(l.groupInviteExpiredNote, style: TextStyle(color: t.muted)),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('invite-create-new'),
              onPressed: _busy ? null : _create,
              child: Text(l.groupInviteCreateNew),
            ),
          ),
        ];
      } else {
        final expiry = current.expiresAt?.toLocal();
        final localizations = MaterialLocalizations.of(context);
        final timeRow = SisSettingsRow(
          key: const ValueKey('invite-time'),
          icon: Icons.schedule_outlined,
          title: l.groupInviteTimeLimit,
          value: _days == null
              ? l.groupInviteNoLimit
              : l.groupInviteDays(_days!),
          onTap: _pickTime,
          showArrow: false,
        );
        final copyRow = SisSettingsRow(
          key: const ValueKey('invite-copy'),
          icon: Icons.copy_outlined,
          title: l.videoPlayerCopy,
          onTap: _copy,
          showArrow: false,
        );
        final shareRow = SisSettingsRow(
          key: const ValueKey('invite-share'),
          icon: Icons.ios_share,
          title: l.groupInviteShare,
          onTap: _share,
          showArrow: false,
        );
        final resetRow = SisSettingsRow(
          key: const ValueKey('invite-reset'),
          icon: Icons.sync,
          title: l.groupInviteReset,
          onTap: _reset,
          showArrow: false,
        );
        final turnOffRow = SisSettingsRow(
          key: const ValueKey('invite-turn-off'),
          icon: Icons.link_off,
          title: l.groupInviteTurnOff,
          iconColor: Theme.of(context).colorScheme.error,
          onTap: _turnOff,
          showArrow: false,
        );
        content = [
          Text(l.groupInviteHelp, style: TextStyle(color: t.muted)),
          InviteLinkBox(text: text),
          if (_offline)
            InviteRedBox(
              text: l.groupInviteOffline,
              keyId: 'invite-offline-box',
            ),
          if (_failed) ...[
            InviteRedBox(
              text: l.groupInviteSaveFailed,
              keyId: 'invite-error-box',
            ),
            TextButton(
              key: const ValueKey('invite-retry'),
              onPressed: _retry,
              child: Text(l.commonTryAgain),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            color: t.surfaceHigh,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _greyed(
                  _offline,
                  'invite-time',
                  l.groupInviteTimeLimit,
                  timeRow,
                ),
                if (expiry != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      l.groupInviteValidUntil(
                        localizations.formatMediumDate(expiry),
                        localizations.formatTimeOfDay(
                          TimeOfDay.fromDateTime(expiry),
                        ),
                      ),
                      key: const ValueKey('invite-valid-until'),
                      style: TextStyle(color: t.muted),
                    ),
                  ),
                copyRow,
                shareRow,
                _greyed(_offline, 'invite-reset', l.groupInviteReset, resetRow),
                _greyed(
                  _offline,
                  'invite-turn-off',
                  l.groupInviteTurnOff,
                  turnOffRow,
                ),
              ],
            ),
          ),
        ];
      }
    }

    return Scaffold(
      key: const ValueKey('group-invite-page'),
      appBar: AppBar(title: Text(l.groupInviteTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const SisProgressLine(key: ValueKey('invite-progress')),
          InviteGroupHeader(
            title: widget.title,
            seed: id,
            memberCount: count,
            avatarPath: avatarPath,
          ),
          ...content,
        ],
      ),
    );
  }

  Widget _greyed(bool grey, String name, String label, Widget child) =>
      grey ? GreyOption(name: name, label: label, child: child) : child;

  String? _currentText() {
    final link = ref.read(inviteLinkProvider(widget.conversationId)).value;
    if (link == null) return null;
    return inviteText(
      link.token,
      ref.read(runtimeConfigProvider).inviteLinkBase,
    );
  }

  Future<void> _run(
    Future<Result<Object?>> Function() call, {
    String? done,
  }) async {
    setState(() {
      _busy = true;
      _offline = false;
      _failed = false;
    });
    final r = await call();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r) {
      case Ok():
        if (done != null) showSisNotice(context, done);
      case Err(:final failure):
        setState(() {
          if (failure is NetworkFailure && failure.retryable) {
            _offline = true;
          } else {
            _failed = true;
          }
          _retry = () => _run(call, done: done);
        });
    }
  }

  Future<void> _create() async {
    final id = widget.conversationId;
    await _run(
      () => ref.read(inviteLinkControllerProvider).reset(id, validDays: null),
    );
  }

  Future<void> _copy() async {
    final text = _currentText();
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showSisNotice(context, AppLocalizations.of(context).videoPlayerCopied);
  }

  Future<void> _share() async {
    final text = _currentText();
    if (text == null) return;
    await ref
        .read(textSharerProvider)
        .share(AppLocalizations.of(context).groupInviteShareText(text));
  }

  Future<void> _pickTime() async {
    final picked = await showInviteTimeSheet(context, current: _days);
    if (picked == null || !mounted || picked.days == _days) return;
    final days = picked.days;
    await _run(
      () => ref
          .read(inviteLinkControllerProvider)
          .setExpiry(widget.conversationId, validDays: days),
    );
  }

  Future<void> _reset() async {
    final l = AppLocalizations.of(context);
    final ok = await showInviteConfirm(
      context,
      title: l.groupInviteResetTitle,
      body: l.groupInviteResetBody,
      action: l.wallpaperResetAction,
    );
    if (!ok || !mounted) return;
    final id = widget.conversationId;
    await _run(
      () => ref.read(inviteLinkControllerProvider).reset(id, validDays: _days),
      done: AppLocalizations.of(context).groupInviteResetDone,
    );
  }

  Future<void> _turnOff() async {
    final l = AppLocalizations.of(context);
    final ok = await showInviteConfirm(
      context,
      title: l.groupInviteTurnOffTitle,
      body: l.groupInviteTurnOffBody,
      action: l.groupInviteTurnOffAction,
    );
    if (!ok || !mounted) return;
    final id = widget.conversationId;
    await _run(
      () => ref.read(inviteLinkControllerProvider).turnOff(id),
      done: AppLocalizations.of(context).groupInviteTurnedOff,
    );
  }
}
