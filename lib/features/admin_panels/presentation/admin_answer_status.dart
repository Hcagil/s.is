import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';
import '../domain/admin_answer.dart';

class AdminAnswerStatusLine extends ConsumerStatefulWidget {
  const AdminAnswerStatusLine({super.key, required this.answer});

  final AdminAnswer answer;

  @override
  ConsumerState<AdminAnswerStatusLine> createState() =>
      _AdminAnswerStatusLineState();
}

class _AdminAnswerStatusLineState extends ConsumerState<AdminAnswerStatusLine> {
  bool _busy = false;

  Future<void> _retry(bool asNew) async {
    setState(() => _busy = true);
    final f = await ref
        .read(adminPanelsProvider.notifier)
        .retryAnswer(widget.answer, asNewConversation: asNew);
    if (!mounted) return;
    setState(() => _busy = false);
    if (f != null) {
      showSisNotice(
        context,
        AppLocalizations.of(context).adminSendFailed,
        isError: true,
      );
    }
  }

  String _reason(AppLocalizations l, AdminAnswerCode? code) => switch (code) {
    AdminAnswerCode.convMissing => l.adminReasonConvMissing,
    AdminAnswerCode.notOpen => l.adminReasonNotOpen,
    AdminAnswerCode.deskOnly => l.adminReasonDeskOnly,
    AdminAnswerCode.unknownItem => l.adminReasonUnknownItem,
    AdminAnswerCode.badConv ||
    AdminAnswerCode.badRequest ||
    null => l.adminReasonGeneric,
  };

  Widget _retryButtons(AppLocalizations l) {
    final answer = widget.answer;
    return Wrap(
      spacing: 8,
      children: [
        TextButton(
          key: const ValueKey('admin-answer-retry'),
          onPressed: _busy ? null : () => _retry(false),
          child: Text(l.adminAnswerRetry),
        ),
        if (answer.kind == 'talk' &&
            answer.code == AdminAnswerCode.convMissing &&
            answer.conv != null)
          TextButton(
            key: const ValueKey('admin-answer-new-conv'),
            onPressed: _busy ? null : () => _retry(true),
            child: Text(l.adminAnswerNewConversation),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final answer = widget.answer;
    if (answer.status == AdminAnswerStatus.sent) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final muted = SisBrand.of(context).muted;
    final TextStyle mutedStyle = TextStyle(color: muted);

    final List<Widget> body = switch (answer.status) {
      AdminAnswerStatus.sent => const <Widget>[],
      AdminAnswerStatus.sending => [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(l.adminAnswerSending, style: mutedStyle),
        ),
      ],
      AdminAnswerStatus.notSentYet => [
        Text(l.adminAnswerNotSentYet, style: mutedStyle),
        _retryButtons(l),
      ],
      AdminAnswerStatus.notSent => [
        Text(l.adminAnswerNotSent, style: mutedStyle),
        Text(_reason(l, answer.code), style: mutedStyle),
        _retryButtons(l),
      ],
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        key: const ValueKey('admin-answer-status'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: body,
      ),
    );
  }
}
