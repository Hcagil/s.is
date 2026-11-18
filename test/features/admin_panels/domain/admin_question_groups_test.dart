import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/domain/admin_models.dart';
import 'package:sis/features/admin_panels/domain/admin_question_groups.dart';

AdminQuestion mk(String id, {String? topic, String? sub, String? conv}) {
  final fields = <String, Object?>{
    'id': id,
    'question': 'text $id',
    'answers': ['a', 'b'],
  };
  if (topic != null) fields['topic'] = topic;
  if (sub != null) fields['sub'] = sub;
  if (conv != null) fields['conv'] = conv;
  return AdminQuestion.fromFields(fields);
}

void main() {
  group('AdminQuestion.fromFields', () {
    test('topic chat', () {
      final q = mk('Q-1', topic: 'chat');
      expect(q.topic, 'chat');
    });

    test('topic nonsense', () {
      final q = mk('Q-2', topic: 'nonsense');
      expect(q.topic, 'other');
    });

    test('topic missing', () {
      final q = mk('Q-3');
      expect(q.topic, 'other');
    });

    test('sub missing', () {
      final q = mk('Q-4');
      expect(q.sub, '');
    });

    test('sub 200 chars kept', () {
      final sub = 'x' * 200;
      final q = mk('Q-5', sub: sub);
      expect(q.sub, sub);
      expect(q.sub.length, 200);
    });

    test('sub 201 chars cut to 200', () {
      final sub = 'x' * 201;
      final q = mk('Q-6', sub: sub);
      expect(q.sub.length, 200);
      expect(q.sub, 'x' * 200);
    });

    test('sub 500 chars cut to 200', () {
      final sub = 'x' * 500;
      final q = mk('Q-7', sub: sub);
      expect(q.sub.length, 200);
      expect(q.sub, 'x' * 200);
    });

    test('conv missing', () {
      final q = mk('Q-8');
      expect(q.conv, null);
    });

    test('conv empty string', () {
      final q = mk('Q-9', conv: '');
      expect(q.conv, null);
    });

    test('conv non-empty', () {
      final q = mk('Q-10', conv: 'c-12');
      expect(q.conv, 'c-12');
    });
  });

  group('admin keys', () {
    test('adminTopicKey', () {
      expect(adminTopicKey('chat'), 'chat');
    });

    test('adminSubKey', () {
      expect(adminSubKey('chat', 'a'), 'chat|a');
    });
  });

  group('groupAdminQuestions', () {
    test('empty list', () {
      final topics = groupAdminQuestions([]);
      expect(topics, isEmpty);
    });

    test('multiple topics', () {
      final qs = [
        mk('Q-1', topic: 'chat'),
        mk('Q-2', topic: 'chat'),
        mk('Q-3', topic: 'tools'),
      ];
      final topics = groupAdminQuestions(qs);
      expect(topics.length, 2);
      final chat = topics.firstWhere((t) => t.name == 'chat');
      expect(chat.questions.map((q) => q.id).toSet(), {'Q-1', 'Q-2'});
      final tools = topics.firstWhere((t) => t.name == 'tools');
      expect(tools.questions.map((q) => q.id).toSet(), {'Q-3'});
    });

    test('sub grouping', () {
      final qs = [
        mk('Q-1', topic: 'chat', sub: 'a'),
        mk('Q-2', topic: 'chat', sub: 'a'),
        mk('Q-3', topic: 'chat', sub: 'b'),
      ];
      final topics = groupAdminQuestions(qs);
      final chat = topics.firstWhere((t) => t.name == 'chat');
      expect(chat.subs.length, 2);
      final subA = chat.subs.firstWhere((s) => s.name == 'a');
      expect(subA.questions.map((q) => q.id).toSet(), {'Q-1', 'Q-2'});
      final subB = chat.subs.firstWhere((s) => s.name == 'b');
      expect(subB.questions.map((q) => q.id).toSet(), {'Q-3'});
    });

    test('empty sub', () {
      final qs = [mk('Q-1', topic: 'chat', sub: '')];
      final topics = groupAdminQuestions(qs);
      final chat = topics.firstWhere((t) => t.name == 'chat');
      final sub = chat.subs.firstWhere((s) => s.name == '');
      expect(sub.questions.map((q) => q.id).toSet(), {'Q-1'});
    });

    test('unknown topic to other', () {
      final qs = [mk('Q-1', topic: 'unknown')];
      final topics = groupAdminQuestions(qs);
      final other = topics.firstWhere((t) => t.name == 'other');
      expect(other.questions.map((q) => q.id).toSet(), {'Q-1'});
    });

    test('no empty topics or subs', () {
      final qs = [
        mk('Q-1', topic: 'chat'),
        mk('Q-2', topic: 'chat', sub: 'a'),
        mk('Q-3', topic: 'tools'),
      ];
      final topics = groupAdminQuestions(qs);
      for (final t in topics) {
        expect(t.questions.isNotEmpty, true);
        for (final s in t.subs) {
          expect(s.questions.isNotEmpty, true);
        }
      }
    });

    test('total count preserved', () {
      final qs = [
        mk('Q-1', topic: 'chat'),
        mk('Q-2', topic: 'chat', sub: 'a'),
        mk('Q-3', topic: 'tools'),
        mk('Q-4', topic: 'tools', sub: 'b'),
        mk('Q-5', topic: 'other'),
        mk('Q-6', topic: 'chat', sub: 'a'),
      ];
      final topics = groupAdminQuestions(qs);
      final allIds = topics.expand((t) => t.questions).map((q) => q.id).toSet();
      expect(allIds.length, qs.length);
      expect(allIds, {'Q-1', 'Q-2', 'Q-3', 'Q-4', 'Q-5', 'Q-6'});
    });
  });
}
