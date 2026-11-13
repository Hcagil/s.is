/// A question item from the admin export.
final class AdminQuestion {
  /// Creates an [AdminQuestion] with the given values.
  const AdminQuestion({
    required this.id,
    required this.text,
    required this.ctx,
    required this.kind,
    required this.recommended,
    required this.answers,
    required this.waiting,
  });

  /// Parses values safely using `is` checks. Never throws.
  factory AdminQuestion.fromFields(Map<String, Object?> f) {
    final id = f['id'] is String ? f['id'] as String : '';
    final text = f['question'] is String ? f['question'] as String : '';
    final ctx = f['ctx'] is String ? f['ctx'] as String : '';
    final kind = f['kind'] is String ? f['kind'] as String : 'pick';
    final recommended = f['rec'] is int ? f['rec'] as int? : null;

    final answersRaw = f['answers'];
    final List<String> answers;
    if (answersRaw is List) {
      answers = answersRaw.whereType<String>().toList();
    } else {
      answers = const [];
    }

    final waiting = f['state'] == 'waiting';

    return AdminQuestion(
      id: id,
      text: text,
      ctx: ctx,
      kind: kind,
      recommended: recommended,
      answers: answers,
      waiting: waiting,
    );
  }

  /// The question id (Q-letter-number).
  final String id;

  /// The text of the question.
  final String text;

  /// The why line.
  final String ctx;

  /// pick | yesno | text | action
  final String kind;

  /// The recommended answer index, if any.
  final int? recommended;

  /// The list of possible answers.
  final List<String> answers;

  /// Answered and sent, not yet read by the computer.
  final bool waiting;
}

/// A task item from the admin export.
final class AdminTask {
  /// Creates an [AdminTask] with the given values.
  const AdminTask({
    required this.id,
    required this.name,
    required this.change,
    required this.basis,
    required this.group,
  });

  /// Parses values safely using `is` checks. Never throws.
  factory AdminTask.fromFields(Map<String, Object?> f) {
    final id = f['id'] is String ? f['id'] as String : '';
    final name = f['name'] is String ? f['name'] as String : '';
    final change = f['change'] is String ? f['change'] as String : '';

    final basisRaw = f['basis'];
    final List<String> basis;
    if (basisRaw is List) {
      basis = basisRaw.map((e) => e.toString()).toList();
    } else if (basisRaw is String && basisRaw.isNotEmpty) {
      basis = [basisRaw];
    } else {
      basis = const [];
    }

    final match = RegExp(r'^T-([MCS])-').firstMatch(id);
    final group = match != null ? match.group(1)! : 'M';

    return AdminTask(
      id: id,
      name: name,
      change: change,
      basis: basis,
      group: group,
    );
  }

  /// The task id (T-letter-number).
  final String id;

  /// The name of the task.
  final String name;

  /// One plain sentence of the change.
  final String change;

  /// The decision ids the task is based on.
  final List<String> basis;

  /// The group letter (M, C or S) taken from the id.
  final String group;
}

/// A conversation item from the admin export.
final class AdminConversation {
  /// Creates an [AdminConversation] with the given values.
  const AdminConversation({
    required this.id,
    required this.topic,
    required this.at,
    required this.unread,
    required this.waiting,
  });

  /// Parses values safely using `is` checks. Never throws.
  factory AdminConversation.fromFields(Map<String, Object?> f) {
    final id = f['id'] is String ? f['id'] as String : '';
    final topic = f['topic'] is String ? f['topic'] as String : '';
    final at = f['at'] is int ? f['at'] as int : 0;
    final unread = f['unread'] == true;
    final waiting = f['waiting'] is int ? f['waiting'] as int : 0;

    return AdminConversation(
      id: id,
      topic: topic,
      at: at,
      unread: unread,
      waiting: waiting,
    );
  }

  /// The conversation id.
  final String id;

  /// The topic of the conversation.
  final String topic;

  /// Seconds since the epoch of the newest activity.
  final int at;

  /// Whether the conversation has unread messages.
  final bool unread;

  /// How many owner messages nobody has answered yet.
  final int waiting;
}

/// A message item from the admin export.
final class AdminMessage {
  /// Creates an [AdminMessage] with the given values.
  const AdminMessage({
    required this.id,
    required this.at,
    required this.from,
    required this.text,
    required this.conv,
  });

  /// Parses values safely using `is` checks. Never throws.
  factory AdminMessage.fromFields(Map<String, Object?> f) {
    final id = f['id'] is String ? f['id'] as String : '';
    final at = f['at'] is int ? f['at'] as int : 0;
    final from = f['from'] is String ? f['from'] as String : 'owner';
    final text = f['text'] is String ? f['text'] as String : '';
    final conv = f['conv'] is String ? f['conv'] as String? : null;

    return AdminMessage(id: id, at: at, from: from, text: text, conv: conv);
  }

  /// The message id.
  final String id;

  /// Seconds since the epoch.
  final int at;

  /// owner | manager
  final String from;

  /// The text content of the message.
  final String text;

  /// The conversation this message belongs to, if any.
  final String? conv;
}
