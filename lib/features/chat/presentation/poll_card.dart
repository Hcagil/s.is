import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import '../domain/poll.dart';
import 'poll_voters_sheet.dart';

class PollCard extends ConsumerStatefulWidget {
  const PollCard({
    super.key,
    required this.message,
    required this.ink,
    required this.accent,
    required this.time,
  });

  final Message message;
  final Color ink;
  final Color accent;
  final Widget time;

  @override
  ConsumerState<PollCard> createState() => _PollCardState();
}

class _PollCardState extends ConsumerState<PollCard> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final polls = ref.watch(pollsProvider).value;
    final poll = polls?[widget.message.id];

    if (polls != null && poll == null && !widget.message.sending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(pollsProvider.notifier).ensure(widget.message.id);
        }
      });
    }

    if (poll == null) {
      return Column(
        key: ValueKey('poll-${widget.message.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.message.body,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: widget.ink,
            ),
          ),
          Align(alignment: Alignment.centerRight, child: widget.time),
        ],
      );
    }

    final l = AppLocalizations.of(context);
    final showResults = poll.voted || poll.closed;

    return Column(
      key: ValueKey('poll-${widget.message.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          poll.question,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: widget.ink,
          ),
        ),
        Text(
          poll.closed
              ? l.pollTypeClosed
              : poll.anonymous
              ? l.pollTypeAnonymous
              : l.pollTypePublic,
          style: TextStyle(
            fontSize: 12,
            color: widget.ink.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 8),
        for (final o in poll.options)
          InkWell(
            key: ValueKey('poll-option-${o.id}'),
            onTap: (widget.message.sending || poll.closed)
                ? null
                : () => _tap(poll, o.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: showResults
                        ? Text(
                            '${poll.percent(o)}%',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: widget.ink,
                            ),
                          )
                        : Icon(
                            poll.multiple
                                ? _picked.contains(o.id)
                                      ? Icons.check_box
                                      : Icons.check_box_outline_blank
                                : Icons.radio_button_unchecked,
                            size: 20,
                            color: widget.ink,
                          ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          o.text,
                          style: TextStyle(fontSize: 14, color: widget.ink),
                        ),
                        if (showResults)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                key: ValueKey('poll-bar-${o.id}'),
                                value: poll.voters <= 0
                                    ? 0.0
                                    : (o.votes / poll.voters).clamp(0.0, 1.0),
                                minHeight: 5,
                                color: widget.accent,
                                backgroundColor: widget.ink.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (showResults && poll.mine.contains(o.id))
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.check_circle,
                        size: 16,
                        color: widget.accent,
                        key: ValueKey('poll-mine-${o.id}'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (poll.multiple && !poll.voted && !poll.closed)
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: ValueKey('poll-vote-${poll.messageId}'),
              onPressed: (_picked.isEmpty || widget.message.sending)
                  ? null
                  : () => _vote(poll, Set.of(_picked)),
              child: Text(l.pollVoteButton),
            ),
          ),
        if (!poll.anonymous && showResults && poll.voters > 0)
          TextButton(
            key: ValueKey('poll-view-votes-${poll.messageId}'),
            onPressed: () =>
                showPollVoters(context, poll, widget.message.conversationId),
            child: Text(l.pollViewVotes(poll.voters)),
          ),
        Row(
          children: [
            if (showResults)
              Text(
                poll.voters == 0 ? l.pollNoVotes : l.pollVotes(poll.voters),
                style: TextStyle(
                  fontSize: 12,
                  color: widget.ink.withValues(alpha: 0.7),
                ),
              ),
            const Spacer(),
            widget.time,
          ],
        ),
      ],
    );
  }

  void _tap(Poll poll, String optionId) {
    if (!poll.multiple) {
      _vote(poll, {optionId});
      return;
    }
    if (poll.voted) {
      final next = Set<String>.of(poll.mine);
      if (!next.remove(optionId)) {
        next.add(optionId);
      }
      _vote(poll, next);
      return;
    }
    setState(() {
      if (!_picked.remove(optionId)) {
        _picked.add(optionId);
      }
    });
  }

  Future<void> _vote(Poll poll, Set<String> chosen) async {
    if (_picked.isNotEmpty) {
      setState(_picked.clear);
    }
    final r = await ref
        .read(pollsProvider.notifier)
        .vote(poll.messageId, chosen);
    if (!mounted) return;
    if (r case Err(:final failure)) {
      showSisNotice(
        context,
        failure is PollClosedFailure
            ? AppLocalizations.of(context).pollClosedNotice
            : failure.message,
        isError: true,
      );
    }
  }
}
