import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/poll.dart';

void main() {
  final now = DateTime.utc(2026, 10, 7, 12);

  group('Constants', () {
    test('poll limits', () {
      expect(pollMinOptions, 2);
      expect(pollMaxOptions, 12);
      expect(pollMaxQuestionLength, 255);
      expect(pollMaxOptionLength, 100);
    });
  });

  group('pollPreview', () {
    test('collapses whitespace', () {
      final input = '  Lunch\n\n where?\t ';
      final expected = '\u{1F4CA} Poll: Lunch where?';
      expect(pollPreview(input), equals(expected));
    });
  });

  group('previewText', () {
    test('poll message', () {
      final pollMsg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'What is your favorite color?',
        createdAt: now,
        poll: true,
      );
      expect(previewText(pollMsg), equals(pollPreview(pollMsg.body)));
    });

    test('text message', () {
      final textMsg = Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'Hi',
        createdAt: now,
      );
      expect(previewText(textMsg), equals('Hi'));
    });
  });

  group('cleanPollOptions', () {
    test('trims and drops empty', () {
      final raw = ['  A  ', '   ', '\tB\n', ''];
      final cleaned = cleanPollOptions(raw);
      expect(cleaned, equals(['A', 'B']));
    });
  });

  group('isSendablePoll', () {
    test('valid poll', () {
      final question = 'What?';
      final options = ['Yes', 'No'];
      expect(isSendablePoll(question, options), isTrue);
    });

    test('empty question', () {
      expect(isSendablePoll('', ['Yes', 'No']), isFalse);
    });

    test('question length 255 ok', () {
      expect(isSendablePoll('a' * 255, ['Yes', 'No']), isTrue);
    });

    test('blank question', () {
      expect(isSendablePoll('   ', ['Yes', 'No']), isFalse);
    });

    test('question length 256 rejected', () {
      final long = 'a' * 256;
      expect(isSendablePoll(long, ['Yes', 'No']), isFalse);
    });

    test('1 option rejected', () {
      expect(isSendablePoll('Q', ['Only']), isFalse);
    });

    test('blank options ignored', () {
      expect(isSendablePoll('Q', ['Yes', '   ', 'No']), isTrue);
      expect(isSendablePoll('Q', ['Yes', '   ']), isFalse);
    });

    test('12 options ok', () {
      final opts = List.generate(12, (i) => 'Opt $i');
      expect(isSendablePoll('Q', opts), isTrue);
    });

    test('13 options rejected', () {
      final opts = List.generate(13, (i) => 'Opt $i');
      expect(isSendablePoll('Q', opts), isFalse);
    });

    test('option length 100 ok', () {
      final opt = 'a' * 100;
      expect(isSendablePoll('Q', [opt, 'B']), isTrue);
    });

    test('option length 101 rejected', () {
      final opt = 'a' * 101;
      expect(isSendablePoll('Q', [opt, 'B']), isFalse);
    });
  });

  group('Poll.percent', () {
    final optionA = PollOption(id: 'a', text: 'A', votes: 1);
    final optionB = PollOption(id: 'b', text: 'B', votes: 2);
    final poll = Poll(
      messageId: 'msg',
      question: 'Q',
      options: [optionA, optionB],
      multiple: false,
      anonymous: false,
      closed: false,
      voters: 4,
    );

    test('zero voters', () {
      final zeroVotersPoll = poll.copyWith(voters: 0);
      expect(zeroVotersPoll.percent(optionA), equals(0));
    });

    test('exact percentages', () {
      expect(poll.percent(optionA), equals(25)); // 1/4
      expect(poll.percent(optionB), equals(50)); // 2/4
    });

    test('multiple-choice sum > 100', () {
      final multiPoll = Poll(
        messageId: 'msg',
        question: 'Q',
        options: [
          PollOption(id: 'a', text: 'A', votes: 2),
          PollOption(id: 'b', text: 'B', votes: 1),
        ],
        multiple: true,
        anonymous: false,
        closed: false,
        voters: 2,
      );
      expect(multiPoll.percent(multiPoll.options[0]), equals(100));
      expect(multiPoll.percent(multiPoll.options[1]), equals(50));
    });
  });

  group('Poll.withMyVotes', () {
    final opt1 = PollOption(id: '1', text: 'One', votes: 0);
    final opt2 = PollOption(id: '2', text: 'Two', votes: 0);
    final basePoll = Poll(
      messageId: 'msg',
      question: 'Q',
      options: [opt1, opt2],
      multiple: false,
      anonymous: false,
      closed: false,
      voters: 0,
    );

    test('first vote', () {
      final updated = basePoll.withMyVotes({'1'});
      expect(updated.mine, equals({'1'}));
      expect(updated.voters, equals(1));
      expect(updated.options[0].votes, equals(1));
      expect(updated.options[1].votes, equals(0));
    });

    test('change single choice', () {
      final first = basePoll.withMyVotes({'1'});
      final second = first.withMyVotes({'2'});
      expect(second.mine, equals({'2'}));
      expect(second.voters, equals(1));
      expect(second.options[0].votes, equals(0));
      expect(second.options[1].votes, equals(1));
    });

    test('add second choice in multiple', () {
      final multiBase = Poll(
        messageId: 'msg',
        question: 'Q',
        options: [opt1.withVotes(1), opt2.withVotes(0)],
        multiple: true,
        anonymous: false,
        closed: false,
        voters: 1,
        mine: {'1'},
      );
      final updated = multiBase.withMyVotes({'1', '2'});
      expect(updated.mine, equals({'1', '2'}));
      expect(updated.voters, equals(1));
      expect(updated.options[0].votes, equals(1));
      expect(updated.options[1].votes, equals(1));
    });

    test('retract to empty', () {
      final first = basePoll.withMyVotes({'1'});
      final retract = first.withMyVotes({});
      expect(retract.mine, isEmpty);
      expect(retract.voters, equals(0));
      expect(retract.options[0].votes, equals(0));
    });

    test('never below zero', () {
      // A stale poll where my option already shows 0 votes and nobody voted.
      final stale = basePoll.copyWith(mine: {'1'});
      final out = stale.withMyVotes({});
      expect(out.options[0].votes, equals(0));
      expect(out.voters, equals(0));
    });

    test('original unchanged', () {
      final updated = basePoll.withMyVotes({'1'});
      expect(basePoll.voters, equals(0));
      expect(basePoll.options[0].votes, equals(0));
    });
  });

  group('applyPollChange', () {
    final opt1 = PollOption(id: '1', text: 'One', votes: 1);
    final opt2 = PollOption(id: '2', text: 'Two', votes: 2);
    final poll = Poll(
      messageId: 'msg',
      question: 'Q',
      options: [opt1, opt2],
      multiple: false,
      anonymous: false,
      closed: false,
      voters: 3,
      mine: {'1'},
    );
    final polls = {'msg': poll};

    test('option change', () {
      final change = PollOptionChange('msg', '1', 5);
      final result = applyPollChange(polls, change);
      expect(identical(result, polls), isFalse);
      final updated = result['msg']!;
      expect(updated.options[0].votes, equals(5));
      expect(updated.options[1].votes, equals(2));
      expect(updated.mine, equals({'1'}));
    });

    test('head change', () {
      final change = PollHeadChange('msg', 10, true);
      final result = applyPollChange(polls, change);
      final updated = result['msg']!;
      expect(updated.voters, equals(10));
      expect(updated.closed, isTrue);
      expect(updated.options[0].votes, equals(1));
    });

    test('unknown poll id', () {
      final change = PollOptionChange('unknown', '1', 5);
      final result = applyPollChange(polls, change);
      expect(identical(result, polls), isTrue);
    });

    test('unknown option id', () {
      final change = PollOptionChange('msg', 'unknown', 5);
      final result = applyPollChange(polls, change);
      expect(identical(result, polls), isTrue);
    });

    test('input not mutated', () {
      final change = PollOptionChange('msg', '1', 5);
      final result = applyPollChange(polls, change);
      // original poll unchanged
      expect(polls['msg']!.options[0].votes, equals(1));
      // result poll updated
      expect(result['msg']!.options[0].votes, equals(5));
    });
  });

  group('Message.canEdit', () {
    test('poll message cannot edit', () {
      final pollMsg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'Question',
        createdAt: now,
        poll: true,
      );
      expect(pollMsg.canEdit('u1', now), isFalse);
      final text = Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'Question',
        createdAt: now,
      );
      expect(text.canEdit('u1', now), isTrue);
    });
  });

  group('allowedMessageActions', () {
    test('poll actions', () {
      final pollMsg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'Question',
        createdAt: now,
        poll: true,
      );
      final actions = allowedMessageActions(pollMsg, me: 'u1', now: now);
      expect(actions.contains(MessageAction.reply), isTrue);
      expect(actions.contains(MessageAction.edit), isFalse);
      expect(actions.contains(MessageAction.forward), isFalse);
    });
  });

  group('menuMessageActions', () {
    test('poll with retract and stop', () {
      final pollMsg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'Question',
        createdAt: now,
        poll: true,
      );
      final actions = menuMessageActions(
        pollMsg,
        me: 'u1',
        now: now,
        canRetract: true,
        canStop: true,
      );
      expect(actions[0], equals(MessageAction.reply));
      expect(actions[1], equals(MessageAction.retractVote));
      expect(actions[2], equals(MessageAction.stopPoll));
      expect(actions, isNot(contains(MessageAction.copy)));
      expect(actions, isNot(contains(MessageAction.forward)));
      expect(actions, isNot(contains(MessageAction.edit)));
    });

    test('poll without retract and stop', () {
      final pollMsg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'Question',
        createdAt: now,
        poll: true,
      );
      final actions = menuMessageActions(
        pollMsg,
        me: 'u1',
        now: now,
        canRetract: false,
        canStop: false,
      );
      expect(actions.contains(MessageAction.retractVote), isFalse);
      expect(actions.contains(MessageAction.stopPoll), isFalse);
      expect(actions.contains(MessageAction.reply), isTrue);
    });
  });
}
