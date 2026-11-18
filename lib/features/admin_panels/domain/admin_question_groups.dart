import 'admin_models.dart';

/// A subtopic group containing questions with the same sub name.
final class AdminQuestionSub {
  /// Creates an [AdminQuestionSub] with the given name and questions.
  const AdminQuestionSub(this.name, this.questions);

  /// The name of this subtopic.
  final String name;

  /// The questions in this subtopic, in input order.
  final List<AdminQuestion> questions;
}

/// A topic group containing subtopic groups.
final class AdminQuestionTopic {
  /// Creates an [AdminQuestionTopic] with the given name and subs.
  const AdminQuestionTopic(this.name, this.subs);

  /// The name of this topic.
  final String name;

  /// The subtopic groups in this topic, in order of first appearance.
  final List<AdminQuestionSub> subs;

  /// All questions of all subs in this topic, in input order.
  Iterable<AdminQuestion> get questions => subs.expand((s) => s.questions);
}

/// Groups questions by topic and subtopic.
///
/// Topics appear in the order of [adminQuestionTopics], only if they hold
/// at least one question. Inside a topic, subs appear in order of first
/// appearance of that sub name among the topic's questions. A question whose
/// topic is not in [adminQuestionTopics] goes to 'other'. Sub name '' is its
/// own sub (name '').
List<AdminQuestionTopic> groupAdminQuestions(List<AdminQuestion> list) {
  final topicMap = <String, Map<String, List<AdminQuestion>>>{};

  for (final q in list) {
    final topicKey = adminQuestionTopics.contains(q.topic) ? q.topic : 'other';
    final subMap = topicMap.putIfAbsent(topicKey, () => {});
    subMap.putIfAbsent(q.sub, () => <AdminQuestion>[]).add(q);
  }

  return [
    for (final topicName in adminQuestionTopics)
      if (topicMap[topicName] case final subMap?)
        AdminQuestionTopic(topicName, [
          for (final e in subMap.entries) AdminQuestionSub(e.key, e.value),
        ]),
  ];
}

/// Key of a topic group: the topic name.
String adminTopicKey(String topic) => topic;

/// Key of a sub group: topic and sub joined.
String adminSubKey(String topic, String sub) => '$topic|$sub';
