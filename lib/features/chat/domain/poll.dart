import 'dart:math' show max;

const int pollMinOptions = 2;
const int pollMaxOptions = 12;
const int pollMaxQuestionLength = 255;
const int pollMaxOptionLength = 100;

/// The chat list marks a poll preview with this prefix.
const String pollPreviewPrefix = '\u{1F4CA} Poll: ';

/// The chat list line of a poll: [pollPreviewPrefix] plus the question with
/// every run of whitespace (newlines included) collapsed to one space.
String pollPreview(String question) =>
    '$pollPreviewPrefix${question.trim().replaceAll(RegExp(r'\s+'), ' ')}';

final class PollOption {
  const PollOption({required this.id, required this.text, required this.votes});

  final String id;
  final String text;
  final int votes;

  PollOption withVotes(int votes) =>
      PollOption(id: id, text: text, votes: votes);
}

final class Poll {
  const Poll({
    required this.messageId,
    required this.question,
    required this.options,
    required this.multiple,
    required this.anonymous,
    required this.closed,
    required this.voters,
    this.mine = const <String>{},
  });

  final String messageId;
  final String question;
  final List<PollOption> options;
  final bool multiple;
  final bool anonymous;
  final bool closed;

  /// How many people voted at least once.
  final int voters;

  /// Ids of the options the signed-in member chose (empty = has not voted).
  final Set<String> mine;

  bool get voted => mine.isNotEmpty;

  Poll copyWith({
    List<PollOption>? options,
    bool? closed,
    int? voters,
    Set<String>? mine,
  }) => Poll(
    messageId: messageId,
    question: question,
    options: options ?? this.options,
    multiple: multiple,
    anonymous: anonymous,
    closed: closed ?? this.closed,
    voters: voters ?? this.voters,
    mine: mine ?? this.mine,
  );

  /// The whole-number percentage (0..100) of [voters] that chose [option];
  /// 0 when nobody voted.
  int percent(PollOption option) {
    if (voters <= 0) return 0;
    return (option.votes * 100 / voters).round().clamp(0, 100);
  }

  /// A NEW poll as it reads once the member's choice is exactly [chosen]:
  /// options dropped lose one vote, options added gain one (never below 0),
  /// [voters] follows whether the member had voted and now has. Shows a vote
  /// at once, before the server answers.
  Poll withMyVotes(Set<String> chosen) {
    final had = mine.isNotEmpty;
    final has = chosen.isNotEmpty;
    return copyWith(
      options: [
        for (final o in options)
          if (mine.contains(o.id) && !chosen.contains(o.id))
            o.withVotes(max(0, o.votes - 1))
          else if (!mine.contains(o.id) && chosen.contains(o.id))
            o.withVotes(o.votes + 1)
          else
            o,
      ],
      voters: !had && has
          ? voters + 1
          : had && !has
          ? max(0, voters - 1)
          : voters,
      mine: Set<String>.of(chosen),
    );
  }
}

/// One member's vote on one option; only ever read for polls that are not
/// anonymous (plus your own).
final class PollVote {
  const PollVote({
    required this.messageId,
    required this.optionId,
    required this.userId,
  });

  final String messageId;
  final String optionId;
  final String userId;
}

/// A poll as its creator wrote it, before it is sent.
final class PollDraft {
  const PollDraft({
    required this.question,
    required this.options,
    required this.multiple,
    required this.anonymous,
  });

  final String question;
  final List<String> options;
  final bool multiple;
  final bool anonymous;
}

/// [raw] with every option trimmed and the empty ones dropped, order kept.
List<String> cleanPollOptions(Iterable<String> raw) => [
  for (final o in raw)
    if (o.trim().isNotEmpty) o.trim(),
];

/// Whether the server would accept this question and these options.
bool isSendablePoll(String question, Iterable<String> options) {
  final q = question.trim();
  final clean = cleanPollOptions(options);
  return q.isNotEmpty &&
      q.length <= pollMaxQuestionLength &&
      clean.length >= pollMinOptions &&
      clean.length <= pollMaxOptions &&
      clean.every((o) => o.length <= pollMaxOptionLength);
}

/// A change to a poll that arrives live.
sealed class PollChange {
  const PollChange(this.messageId);

  final String messageId;
}

/// New absolute vote count of one option.
final class PollOptionChange extends PollChange {
  const PollOptionChange(super.messageId, this.optionId, this.votes);

  final String optionId;
  final int votes;
}

/// New absolute voter count and closed state of a poll.
final class PollHeadChange extends PollChange {
  const PollHeadChange(super.messageId, this.voters, this.closed);

  final int voters;
  final bool closed;
}

/// Polls keyed by message id.
typedef PollsByMessage = Map<String, Poll>;

/// A NEW map with [change] applied (absolute values replace the old ones; the
/// member's own `mine` is kept). A change for a poll or option that is not
/// there returns [polls] itself, so the caller can tell nothing changed.
PollsByMessage applyPollChange(PollsByMessage polls, PollChange change) {
  final poll = polls[change.messageId];
  if (poll == null) return polls;
  final Poll next;
  switch (change) {
    case PollOptionChange(:final optionId, :final votes):
      if (!poll.options.any((o) => o.id == optionId)) return polls;
      next = poll.copyWith(
        options: [
          for (final o in poll.options)
            if (o.id == optionId) o.withVotes(votes) else o,
        ],
      );
    case PollHeadChange(:final voters, :final closed):
      next = poll.copyWith(voters: voters, closed: closed);
  }
  return {...polls, change.messageId: next};
}
