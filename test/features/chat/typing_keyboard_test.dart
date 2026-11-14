// Typing on a phone (0.30.2), written from the contract, not the screen's
// source: sending -- from the send button -- leaves the keyboard up with the cursor in the composer, and the New chat
// sheet's tag box and its result stay above an open keyboard.
//
// The keyboard is the test binding's TestTextInput: it is "visible" while a
// text field holds focus and is hidden the moment focus leaves it, as the
// platform keyboard is.
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/held_send_chat.dart';
import 'contacts_ui_test.dart' as contacts;
import 'instant_send_widget_test.dart' as s;

FocusNode composerFocus(WidgetTester t) => t
    .widget<EditableText>(
      find.descendant(of: s.field, matching: find.byType(EditableText)),
    )
    .focusNode;

/// The cursor is in the composer and the keyboard is up.
void expectTyping(WidgetTester t, String when) {
  expect(
    FocusManager.instance.primaryFocus,
    same(composerFocus(t)),
    reason: 'composer lost focus $when',
  );
  expect(t.testTextInput.isVisible, isTrue, reason: 'keyboard hid $when');
}

Future<void> typeFocused(WidgetTester t, String text) async {
  await t.showKeyboard(s.field);
  t.testTextInput.enterText(text);
  await t.pump();
  expectTyping(t, 'while typing');
}

Future<void> keyboardNewline(WidgetTester t) async {
  await t.testTextInput.receiveAction(TextInputAction.newline);
  await t.pump();
}

Future<void> settleSends(WidgetTester t, HeldSendChat chat) async {
  for (var i = 0; i < chat.asked.length; i++) {
    if (!chat.asked[i].answer.isCompleted) chat.ok(i);
    await t.pump();
  }
  await t.pumpAndSettle();
}

void main() {
  group('the composer keeps the keyboard up after a send', () {
    testWidgets('composer field: keyboard action is newline, multiline', (
      t,
    ) async {
      final chat = HeldSendChat()..history['c1'] = [s.msg('m1')];
      await s.pump(t, chat);

      final field = t.widget<TextField>(s.field);
      expect(field.textInputAction, TextInputAction.newline);
      expect(field.keyboardType, TextInputType.multiline);
    });

    testWidgets('keyboard action key does not send and keeps the text', (
      t,
    ) async {
      final chat = HeldSendChat()..history['c1'] = [s.msg('m1')];
      await s.pump(t, chat);

      await typeFocused(t, 'hello');
      await keyboardNewline(t);

      expect(chat.asked, isEmpty);
      expect(s.composerText(t), 'hello');
      expectTyping(t, 'after the keyboard action');
      expect(s.send, findsOneWidget);
    });

    testWidgets(
      'send button after the keyboard action: sends once, empties, keeps focus',
      (t) async {
        final chat = HeldSendChat()..history['c1'] = [s.msg('m1')];
        await s.pump(t, chat);

        await typeFocused(t, 'hello');
        await keyboardNewline(t);
        await t.tap(s.send);
        await t.pump();

        expect(chat.asked.map((a) => a.body), ['hello']);
        expect(s.composerText(t), isEmpty);
        expectTyping(t, 'after tapping send');
        await settleSends(t, chat);
        expect(chat.asked, hasLength(1));
      },
    );

    testWidgets('send button: one send, field empty, still typing', (t) async {
      final chat = HeldSendChat()..history['c1'] = [s.msg('m1')];
      await s.pump(t, chat);

      await typeFocused(t, 'hello');
      await t.tap(s.send);
      await t.pump();

      expect(chat.asked.map((a) => a.body), ['hello']);
      expect(s.composerText(t), isEmpty);
      expectTyping(t, 'after tapping send');

      await t.pump(const Duration(milliseconds: 300));
      expectTyping(t, 'a moment after tapping send');
      await settleSends(t, chat);
      expectTyping(t, 'after the server answered');
    });

    // A stylus (S Pen, Apple Pencil) or mouse tap outside a text field drops
    // its focus on Android and iOS, unlike a finger. The send button must
    // still leave the cursor in the composer.
    for (final kind in [PointerDeviceKind.stylus, PointerDeviceKind.mouse]) {
      testWidgets(
        'send button tapped with a ${kind.name}: still typing',
        (t) async {
          final chat = HeldSendChat()..history['c1'] = [s.msg('m1')];
          await s.pump(t, chat);

          await typeFocused(t, 'hello');
          await t.tap(s.send, kind: kind);
          await t.pump();

          expect(chat.asked.map((a) => a.body), ['hello']);
          expect(s.composerText(t), isEmpty);
          expectTyping(t, 'after a ${kind.name} tap on send');
          await settleSends(t, chat);
          expectTyping(t, 'after the server answered');
        },
        variant: TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }

    testWidgets('empty or whitespace never sends', (t) async {
      final chat = HeldSendChat()..history['c1'] = [s.msg('m1')];
      await s.pump(t, chat);

      await typeFocused(t, '   ');
      await keyboardNewline(t);
      await t.tap(s.send);
      await t.pump();
      expectTyping(t, 'after tapping send on spaces');

      await t.showKeyboard(s.field);
      t.testTextInput.enterText('');
      await t.pump();
      await keyboardNewline(t);
      expectTyping(t, 'after a keyboard action of nothing');

      await t.pumpAndSettle();
      expect(chat.asked, isEmpty, reason: 'nothing to send');
    });

    testWidgets(
      'the keyboard action key while editing a message does not send and does not save',
      (t) async {
        final chat = HeldSendChat()
          ..history['c1'] = [s.msg('m1', body: 'mine', from: me.userId)];
        await s.pump(t, chat);

        await t.longPress(s.bubble('m1'));
        await t.pumpAndSettle();
        await t.tap(s.editAction);
        await t.pumpAndSettle();
        expect(s.editBar, findsOneWidget, reason: 'edit mode did not open');

        await typeFocused(t, 'mine, edited');
        await keyboardNewline(t);
        expect(chat.asked, isEmpty, reason: 'an edit is not a new message');
        expect(chat.edits.length, lessThanOrEqualTo(1), reason: 'saved twice');
        expect(s.editBar, findsOneWidget);
        expect(s.composerText(t), 'mine, edited');
      },
    );
  });

  group('New chat sheet above the keyboard', () {
    const inset = 300.0;
    // 390 wide: at 360 the home screen's New chat button row overflows
    // before the sheet is ever opened (a separate, pre-existing defect).
    const screen = Size(390, 640);

    testWidgets('the tag box and its result stay above the keyboard', (
      t,
    ) async {
      t.view
        ..physicalSize = screen
        ..devicePixelRatio = 1;
      addTearDown(t.view.reset);

      final w = contacts.World();
      await contacts.pumpApp(t, w);
      await contacts.openNewChat(t);

      final tagField = contacts.byKey('find-by-tag-field');
      await t.showKeyboard(tagField);
      t.view.viewInsets = const FakeViewPadding(bottom: inset);
      await contacts.steps(t);

      t.testTextInput.enterText('cem');
      await t.pump();
      await t.tap(contacts.byKey('find-by-tag-submit'), warnIfMissed: false);
      await contacts.steps(t);

      final result = contacts.byKey('find-by-tag-result-u3');
      expect(result, findsOneWidget, reason: 'search did not find Cem');
      const top = 0.0, keyboardTop = 640 - inset;
      for (final (name, f) in [('tag field', tagField), ('result', result)]) {
        final r = t.getRect(f);
        expect(r.top, greaterThanOrEqualTo(top), reason: '$name off the top');
        expect(
          r.bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: '$name under the keyboard: $r',
        );
      }
    });
  });
}
