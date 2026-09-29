import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/timeline.dart';

/// Helper to create a message with a given [id] and [createdAt].
Message _msg(String id, DateTime createdAt) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 's1',
  body: 'body',
  createdAt: createdAt,
);

/// Helper to create an event with a given [id], [kind] and [createdAt].
GroupEvent _event(String id, GroupEventKind kind, DateTime createdAt) =>
    GroupEvent(
      id: id,
      conversationId: 'c1',
      kind: kind,
      subjectId: 'sub',
      createdAt: createdAt,
      actorId: null,
    );

/// Maps a [TimelineEntry] to a string that uniquely identifies it.
String _entryId(TimelineEntry entry) {
  if (entry is MessageEntry) {
    return 'm:${entry.message.id}';
  } else if (entry is EventEntry) {
    return 'e:${entry.event.id}';
  }
  throw ArgumentError('Unknown TimelineEntry type');
}

void main() {
  group('buildTimeline', () {
    test('returns empty list when both inputs are empty', () {
      final result = buildTimeline([], []);
      expect(result, isEmpty);
    });

    test('returns messages only when events list is empty', () {
      final m1 = _msg('m1', DateTime.utc(2026, 9, 29, 10, 0, 0));
      final m2 = _msg('m2', DateTime.utc(2026, 9, 29, 11, 0, 0));
      final result = buildTimeline([m1, m2], []);
      expect(result.length, 2);
      expect(result[0], isA<MessageEntry>());
      expect(result[1], isA<MessageEntry>());
      expect(_entryId(result[0]), 'm:m1');
      expect(_entryId(result[1]), 'm:m2');
    });

    test('returns events only when messages list is empty', () {
      final e1 = _event(
        'e1',
        GroupEventKind.added,
        DateTime.utc(2026, 9, 29, 9, 0, 0),
      );
      final e2 = _event(
        'e2',
        GroupEventKind.left,
        DateTime.utc(2026, 9, 29, 12, 0, 0),
      );
      final result = buildTimeline([], [e1, e2]);
      expect(result.length, 2);
      expect(result[0], isA<EventEntry>());
      expect(result[1], isA<EventEntry>());
      expect(_entryId(result[0]), 'e:e1');
      expect(_entryId(result[1]), 'e:e2');
    });

    test('interleaves messages and events correctly', () {
      final m1 = _msg('m1', DateTime.utc(2026, 9, 29, 10, 0, 0));
      final m2 = _msg('m2', DateTime.utc(2026, 9, 29, 11, 0, 0));
      final m3 = _msg('m3', DateTime.utc(2026, 9, 29, 12, 0, 0));
      final e1 = _event(
        'e1',
        GroupEventKind.added,
        DateTime.utc(2026, 9, 29, 10, 30, 0),
      );
      final e2 = _event(
        'e2',
        GroupEventKind.left,
        DateTime.utc(2026, 9, 29, 11, 30, 0),
      );
      final result = buildTimeline([m1, m2, m3], [e1, e2]);

      final ids = result.map(_entryId).toList();
      expect(ids, equals(['m:m1', 'e:e1', 'm:m2', 'e:e2', 'm:m3']));
    });

    test('sorts events that are given in any order', () {
      final m1 = _msg('m1', DateTime.utc(2026, 9, 29, 10, 0, 0));
      final m2 = _msg('m2', DateTime.utc(2026, 9, 29, 11, 0, 0));
      final e1 = _event(
        'e1',
        GroupEventKind.added,
        DateTime.utc(2026, 9, 29, 12, 0, 0),
      );
      final e2 = _event(
        'e2',
        GroupEventKind.left,
        DateTime.utc(2026, 9, 29, 9, 0, 0),
      );
      final result = buildTimeline([m1, m2], [e1, e2]);

      final ids = result.map(_entryId).toList();
      expect(ids, equals(['e:e2', 'm:m1', 'm:m2', 'e:e1']));
    });

    test('message precedes event when timestamps are equal', () {
      final t = DateTime.utc(2026, 9, 29, 10, 0, 0);
      final m = _msg('m1', t);
      final e = _event('e1', GroupEventKind.added, t);
      final result = buildTimeline([m], [e]);

      expect(_entryId(result[0]), 'm:m1');
      expect(_entryId(result[1]), 'e:e1');
    });

    test('events with equal timestamps preserve input order', () {
      final t = DateTime.utc(2026, 9, 29, 10, 0, 0);
      final e1 = _event('e1', GroupEventKind.added, t);
      final e2 = _event('e2', GroupEventKind.left, t);
      final result = buildTimeline([], [e2, e1]); // input order reversed

      final ids = result.map(_entryId).toList();
      expect(ids, equals(['e:e2', 'e:e1']));
    });

    test('handles UTC and local DateTime that represent the same instant', () {
      final utc = DateTime.utc(2026, 9, 29, 10, 0, 0);
      final local = utc.toLocal(); // same instant, different timezone
      final eUtc = _event('eUtc', GroupEventKind.added, utc);
      final eLocal = _event('eLocal', GroupEventKind.left, local);
      final result = buildTimeline([], [eUtc, eLocal]);

      final ids = result.map(_entryId).toList();
      // Since both timestamps are equal, the relative order from input should be preserved.
      expect(ids, equals(['e:eUtc', 'e:eLocal']));
      // ... and the reverse input keeps its own order: equal, not "local first".
      expect(
        buildTimeline([], [eLocal, eUtc]).map(_entryId).toList(),
        equals(['e:eLocal', 'e:eUtc']),
      );
    });

    test('a message and an event at the same instant, one in local time: '
        'the message still comes first', () {
      final utc = DateTime.utc(2026, 9, 29, 10);
      final m = _msg('m1', utc.toLocal());
      final e = _event('e1', GroupEventKind.removed, utc);
      expect(buildTimeline([m], [e]).map(_entryId).toList(), ['m:m1', 'e:e1']);
      // A later message stays after the event.
      final m2 = _msg('m2', utc.add(const Duration(seconds: 1)));
      expect(buildTimeline([m, m2], [e]).map(_entryId).toList(), [
        'm:m1',
        'e:e1',
        'm:m2',
      ]);
    });

    test(
      'an event sharing its instant with the later message goes after it',
      () {
        final t0 = DateTime.utc(2026, 9, 29, 10);
        final t1 = DateTime.utc(2026, 9, 29, 11);
        final e = _event('e1', GroupEventKind.left, t1);
        expect(
          buildTimeline([_msg('m1', t0), _msg('m2', t1)], [e]).map(_entryId),
          ['m:m1', 'm:m2', 'e:e1'],
        );
      },
    );

    test('does not mutate input lists', () {
      final m1 = _msg('m1', DateTime.utc(2026, 9, 29, 10, 0, 0));
      final e1 = _event(
        'e1',
        GroupEventKind.added,
        DateTime.utc(2026, 9, 29, 9, 0, 0),
      );
      final messages = [m1];
      final events = [e1];

      buildTimeline(messages, events);

      expect(messages, equals([m1]));
      expect(events, equals([e1]));
    });

    test('output contains all entries exactly once', () {
      final m1 = _msg('m1', DateTime.utc(2026, 9, 29, 10, 0, 0));
      final m2 = _msg('m2', DateTime.utc(2026, 9, 29, 11, 0, 0));
      final e1 = _event(
        'e1',
        GroupEventKind.added,
        DateTime.utc(2026, 9, 29, 9, 0, 0),
      );
      final e2 = _event(
        'e2',
        GroupEventKind.left,
        DateTime.utc(2026, 9, 29, 12, 0, 0),
      );

      final result = buildTimeline([m1, m2], [e1, e2]);

      final ids = result.map(_entryId).toSet();
      expect(ids, equals({'m:m1', 'm:m2', 'e:e1', 'e:e2'}));
      expect(result.length, 4);
    });

    test('output is sorted by timestamp ascending', () {
      final m1 = _msg('m1', DateTime.utc(2026, 9, 29, 10, 0, 0));
      final m2 = _msg('m2', DateTime.utc(2026, 9, 29, 11, 0, 0));
      final e1 = _event(
        'e1',
        GroupEventKind.added,
        DateTime.utc(2026, 9, 29, 9, 0, 0),
      );
      final e2 = _event(
        'e2',
        GroupEventKind.left,
        DateTime.utc(2026, 9, 29, 12, 0, 0),
      );

      final result = buildTimeline([m1, m2], [e1, e2]);

      final times = result.map((e) => e.at).toList();
      expect(times, equals([...times]..sort()));
    });
  });
}
