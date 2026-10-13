import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import '../domain/poll.dart';
import 'message_menu_card.dart';

/// Opens the list of who voted for what on a public poll.
Future<void> showPollVoters(
  BuildContext context,
  Poll poll,
  String conversationId,
) {
  return showFloatingCard<void>(
    context,
    anchor: Rect.fromCenter(
      center: MediaQuery.sizeOf(context).center(Offset.zero),
      width: 0,
      height: 0,
    ),
    highlightAnchor: false,
    cardKey: const ValueKey('poll-voters-card'),
    child: _Voters(poll: poll, conversationId: conversationId),
  );
}

class _Voters extends ConsumerWidget {
  const _Voters({required this.poll, required this.conversationId});

  final Poll poll;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final votes = ref.watch(pollVotesProvider(poll.messageId)).value;
    final members =
        ref.watch(conversationMembersProvider(conversationId)).value ??
        const <Member>[];
    String nameOf(String userId) {
      for (final m in members) {
        if (m.userId == userId) return m.displayName;
      }
      return '';
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.pollResultsTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final option in poll.options)
                      Column(
                        key: ValueKey('poll-voters-${option.id}'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  option.text,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Text(l.pollOptionVoters(option.votes)),
                            ],
                          ),
                          for (final vote in votes ?? const <PollVote>[])
                            if (vote.optionId == option.id)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
                                child: Text(
                                  nameOf(vote.userId),
                                  key: ValueKey(
                                    'poll-voter-${option.id}-${vote.userId}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          const SizedBox(height: 12),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
