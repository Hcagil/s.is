import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/message.dart';

import 'fakes.dart';

/// The signed-in member the held sends are written by.
const me = Member(userId: 'u1', displayName: 'Maya');

/// One send the server has been asked for, still waiting for its answer.
class Ask {
  Ask(this.id, this.conversationId, this.body, this.replyTo)
    : stored = Message(
        id: id,
        conversationId: conversationId,
        senderId: me.userId,
        body: body.trim(),
        createdAt: DateTime.now(),
        replyTo: replyTo,
      );

  /// The id the phone chose; the server stores the row under it.
  final String id;
  final String conversationId;
  final String body;
  final String? replyTo;

  /// The row the server writes for it -- what it answers with, and what
  /// Realtime echoes.
  final Message stored;
  final answer = Completer<Result<Message>>();
}

/// [ChatFake] whose sends wait for the server's answer until the test gives
/// it, recording what was asked, in order, and how many were in flight.
class HeldSendChat extends ChatFake {
  HeldSendChat() : super(self: me.userId);

  final asked = <Ask>[];
  int inFlight = 0;
  int maxInFlight = 0;

  /// Called at the moment the server is asked, before anything is answered.
  void Function(Ask)? onAsk;

  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String body,
    String? replyTo,
  }) async {
    final ask = Ask(id, conversationId, body, replyTo);
    asked.add(ask);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    onAsk?.call(ask);
    try {
      return await ask.answer.future;
    } finally {
      inFlight--;
    }
  }

  void ok(int i) => asked[i].answer.complete(Ok(asked[i].stored));
  void fail(int i, Failure f) => asked[i].answer.complete(Err(f));

  /// The server wrote ask [i]'s row and Realtime delivers it.
  void echo(int i) => deliver(asked[i].stored);
}
