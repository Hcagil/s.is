import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/invite_link_controller.dart';
import '../domain/invite_link.dart';
import 'invite_refused_page.dart';
import 'invite_widgets.dart';
import 'message_screen.dart';

class InviteJoinPage extends ConsumerStatefulWidget {
  const InviteJoinPage({super.key, required this.code, required this.preview});

  final String code;
  final InvitePreview preview;

  @override
  ConsumerState<InviteJoinPage> createState() => _InviteJoinPageState();
}

class _InviteJoinPageState extends ConsumerState<InviteJoinPage> {
  bool _joining = false;
  bool _failed = false;
  bool _offline = false;

  Future<void> _openGroup() async {
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    await openConversation(
      navigator.context,
      ref,
      widget.preview.conversationId,
      title: widget.preview.title,
      group: true,
    );
  }

  Future<void> _join() async {
    setState(() {
      _joining = true;
      _failed = false;
    });
    final navigator = Navigator.of(context);
    final l = AppLocalizations.of(context);
    final r = await ref.read(inviteLinkControllerProvider).join(widget.code);
    if (!mounted) return;
    switch (r) {
      case Ok(:final value):
        await ref.read(conversationListProvider.notifier).refresh();
        if (!mounted) return;
        navigator.popUntil((route) => route.isFirst);
        showSisNotice(navigator.context, l.inviteJoinedToast);
        await openConversation(
          navigator.context,
          ref,
          value,
          title: widget.preview.title,
          group: true,
        );
      case Err(failure: final InviteLinkFailure f):
        navigator.pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => InviteRefusedPage(problem: f.problem),
          ),
        );
      case Err(failure: final NetworkFailure f) when f.retryable:
        setState(() {
          _joining = false;
          _offline = true;
        });
      case Err():
        setState(() {
          _joining = false;
          _failed = true;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final preview = widget.preview;
    final member = (ref.watch(conversationListProvider).value ?? const []).any(
      (c) => c.id == preview.conversationId,
    );

    if (member) {
      return Scaffold(
        key: const ValueKey('invite-already-page'),
        appBar: AppBar(title: Text(l.inviteAlreadyTitle)),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InviteGroupHeader(
                title: preview.title,
                seed: preview.conversationId,
                memberCount: preview.memberCount,
              ),
              const SizedBox(height: 16),
              Text(l.inviteAlreadyBody, style: TextStyle(color: t.muted)),
              const Spacer(),
              FilledButton(
                key: const ValueKey('invite-open-group'),
                onPressed: _openGroup,
                child: Text(l.inviteOpenGroup),
              ),
            ],
          ),
        ),
      );
    }

    if (_offline) {
      return Scaffold(
        key: const ValueKey('invite-join-offline-page'),
        appBar: AppBar(title: Text(l.inviteNoInternet)),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.inviteJoinOfflineBody, style: TextStyle(color: t.muted)),
                const SizedBox(height: 12),
                InviteRedBox(
                  text: l.inviteJoinNotDone,
                  keyId: 'invite-join-not-done',
                ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('invite-join-grey'),
                  onPressed: null,
                  child: Text(l.inviteJoinGroup),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      key: const ValueKey('invite-join-page'),
      appBar: AppBar(title: Text(l.inviteJoinGroup)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // No avatarPath on purpose: non-members cannot load the group picture.
              InviteGroupHeader(
                title: preview.title,
                seed: preview.conversationId,
                memberCount: preview.memberCount,
              ),
              const SizedBox(height: 16),
              if (preview.newMembersSeeHistory case final sees?)
                Text(
                  sees ? l.addMembersOldHint : l.inviteJoinNoHistory,
                  key: const ValueKey('invite-join-history'),
                  style: TextStyle(color: SisBrand.of(context).muted),
                ),
              if (_joining)
                Text(
                  l.inviteJoiningStatus,
                  key: const ValueKey('invite-joining-status'),
                  style: TextStyle(color: t.muted),
                ),
              if (_failed) ...[
                const SizedBox(height: 12),
                InviteRedBox(
                  text: l.inviteJoinFailed,
                  keyId: 'invite-join-error',
                ),
              ],
              const Spacer(),
              FilledButton(
                key: const ValueKey('invite-join-button'),
                onPressed: _joining ? null : _join,
                child: Text(
                  _joining
                      ? l.inviteJoining
                      : _failed
                      ? l.commonTryAgain
                      : l.inviteJoinGroup,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
