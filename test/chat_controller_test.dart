import 'package:flutter_test/flutter_test.dart';
import 'package:sis/chat_controller.dart';

void main() {
  test('send trims and stores a message', () {
    final controller = ChatController();

    expect(controller.send('  Hello friends  '), isTrue);
    expect(controller.messages.single.body, 'Hello friends');
    expect(controller.messages.single.isMine, isTrue);
  });

  test('send rejects an empty message', () {
    final controller = ChatController();

    expect(controller.send('   '), isFalse);
    expect(controller.messages, isEmpty);
  });
}
