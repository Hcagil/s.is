/// Error codes the server returns for an admin answer.
enum AdminAnswerCode {
  convMissing,
  badConv,
  notOpen,
  deskOnly,
  unknownItem,
  badRequest;

  /// Maps a raw server string to a code; anything unknown becomes [badRequest].
  static AdminAnswerCode parse(Object? raw) {
    return switch (raw) {
      'conv_missing' => convMissing,
      'bad_conv' => badConv,
      'not_open' => notOpen,
      'desk_only' => deskOnly,
      'unknown_item' => unknownItem,
      'bad_request' => badRequest,
      _ => badRequest,
    };
  }
}

/// The epoch and sequence number of one up row the phone sent.
final class AdminSentRef {
  const AdminSentRef(this.epoch, this.upSeq);

  final int epoch;
  final int upSeq;
}

/// The server's answer for one up row.
final class AdminAnswerResult {
  const AdminAnswerResult({
    required this.epoch,
    required this.upSeq,
    required this.ok,
    this.code,
  });

  final int epoch;
  final int upSeq;
  final bool ok;
  final AdminAnswerCode? code;
}

/// Parses the decoded "results" list of an answer response; never throws.
List<AdminAnswerResult> parseAnswerResults(Object? raw) {
  if (raw is! List) return const [];
  final result = <AdminAnswerResult>[];
  final seen = <(int, int)>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final upSeq = entry['up_seq'];
    final epoch = entry['epoch'];
    if (upSeq is! int || epoch is! int) continue;
    if (!seen.add((epoch, upSeq))) continue;
    final ok = entry['ok'] == true;
    result.add(
      AdminAnswerResult(
        epoch: epoch,
        upSeq: upSeq,
        ok: ok,
        code: ok ? null : AdminAnswerCode.parse(entry['code']),
      ),
    );
  }
  return result;
}

/// Delivery state of an admin answer.
enum AdminAnswerStatus { sending, sent, notSent, notSentYet }

/// One admin answer the phone sent, kept so it can be sent again.
final class AdminAnswer {
  const AdminAnswer({
    required this.epoch,
    required this.upSeq,
    required this.message,
    required this.sentAt,
    this.status = AdminAnswerStatus.sending,
    this.code,
  });

  final int epoch;
  final int upSeq;
  final Map<String, Object?> message;
  final DateTime sentAt;
  final AdminAnswerStatus status;
  final AdminAnswerCode? code;

  String get kind => message['kind'] as String? ?? '';

  String? get targetId {
    if (kind == 'question' || kind == 'task') {
      return message['id'] as String?;
    }
    return null;
  }

  String? get conv => message['conv'] as String?;

  AdminAnswer copyWith({AdminAnswerStatus? status, AdminAnswerCode? code}) {
    return AdminAnswer(
      epoch: epoch,
      upSeq: upSeq,
      message: message,
      sentAt: sentAt,
      status: status ?? this.status,
      code: code ?? this.code,
    );
  }
}
