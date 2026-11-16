import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';

import 'fakes.dart';

/// One photo upload the server has been asked for, waiting for its answer.
class ImgAsk {
  ImgAsk(this.conversationId, this.image, this.body, this.replyTo);
  final String conversationId;
  final PickedImage image;
  final String body;
  final String? replyTo;
  final answer = Completer<Result<Message>>();
}

class HeldImageChat extends ChatFake {
  HeldImageChat() : super(self: 'u1');
  final asked = <ImgAsk>[];

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) {
    final a = ImgAsk(conversationId, image, body, replyTo);
    asked.add(a);
    return a.answer.future;
  }

  void ok(int i) {
    final a = asked[i];
    a.answer.complete(
      Ok(
        Message(
          id: a.image.id!,
          conversationId: a.conversationId,
          senderId: 'u1',
          body: a.body.trim(),
          createdAt: DateTime.now(),
          attachmentPath: '${a.conversationId}/${a.image.id}.png',
          replyTo: a.replyTo,
        ),
      ),
    );
  }

  void fail(int i, Failure f) => asked[i].answer.complete(Err(f));
}
