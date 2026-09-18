import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/chat_controller.dart';
import 'package:sis/main.dart';

void main() {
  testWidgets('composer disables send for empty input and sends text', (
    tester,
  ) async {
    final controller = ChatController();
    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(controller: controller)),
    );

    final sendButton = find.widgetWithIcon(IconButton, Icons.send_rounded);
    expect(tester.widget<IconButton>(sendButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.pump();
    expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);

    await tester.tap(sendButton);
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);
    expect(controller.messages.single.body, 'Hello');
  });
}
