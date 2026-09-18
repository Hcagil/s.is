import 'package:flutter/foundation.dart';

@immutable
class ChatMessage {
  const ChatMessage({
    required this.sender,
    required this.body,
    required this.isMine,
  });

  final String sender;
  final String body;
  final bool isMine;
}

class ChatController extends ChangeNotifier {
  ChatController([Iterable<ChatMessage> messages = const []])
    : _messages = List.of(messages);

  factory ChatController.withSampleMessages() {
    return ChatController(const [
      ChatMessage(
        sender: 'Maya',
        body: 'Are we still meeting on Saturday?',
        isMine: false,
      ),
      ChatMessage(
        sender: 'You',
        body: 'Yes! I can be there around noon.',
        isMine: true,
      ),
    ]);
  }

  final List<ChatMessage> _messages;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  bool send(String body) {
    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) {
      return false;
    }

    _messages.add(ChatMessage(sender: 'You', body: trimmedBody, isMine: true));
    notifyListeners();
    return true;
  }
}
