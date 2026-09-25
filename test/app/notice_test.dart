// showSisNotice, from its contract in lib/app/notice.dart: the one way SIS
// reports a result -- a floating pill under the header, one line, gone by
// itself after about two seconds, told to screen readers as a live region,
// and different for an error than for a success. Never a SnackBar.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';

import '../support/sis_ui.dart';

const long =
    'This notice is far too long to ever fit on one line of a phone screen, '
    'so it has to be cut short with an ellipsis instead of wrapping onto a '
    'second and third line and pushing the rest of the screen around';

/// A screen with a header, and a button that shows [message].
Widget screen(String message, {bool isError = false}) => MaterialApp(
  home: Scaffold(
    appBar: AppBar(title: const Text('Chats')),
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const ValueKey('show'),
          onPressed: () => showSisNotice(context, message, isError: isError),
          child: const Text('Show'),
        ),
      ),
    ),
  ),
);

Future<void> show(
  WidgetTester t,
  String message, {
  bool isError = false,
}) async {
  await t.pumpWidget(screen(message, isError: isError));
  await t.tap(find.byKey(const ValueKey('show')));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400)); // its entrance
}

void main() {
  testWidgets('shows the message as a pill under the header, not a SnackBar', (
    t,
  ) async {
    await show(t, 'Saved');

    expect(notice, findsOneWidget);
    expect(noticeSaying('Saved'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    final pill = t.getRect(notice);
    final header = t.getRect(find.byType(AppBar));
    final screenHeight = t.view.physicalSize.height / t.view.devicePixelRatio;
    expect(
      pill.top,
      greaterThanOrEqualTo(header.bottom),
      reason: 'under the header, not over it',
    );
    expect(
      pill.center.dy,
      lessThan(screenHeight / 2),
      reason: 'near the header, not at the bottom like a SnackBar',
    );
    await drainNotice(t);
  });

  testWidgets('is announced to screen readers as a live region', (t) async {
    await show(t, 'Forwarded');

    final node = t.getSemantics(notice);
    expect(
      node.getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
      reason: 'TalkBack reads a live region as soon as it appears',
    );
    expect(node.label, contains('Forwarded'));
    await drainNotice(t);
  });

  testWidgets('a screen reader hears the message once, not twice', (t) async {
    await show(t, 'Forwarded');

    expect(
      t.getSemantics(notice).label,
      'Forwarded',
      reason:
          'the live region\'s label is the message; the visible text '
          'must not be merged in and read a second time',
    );
    await drainNotice(t);
  });

  testWidgets('dismisses itself after about two seconds', (t) async {
    await show(t, 'Saved');

    await t.pump(const Duration(milliseconds: 1200));
    expect(notice, findsOneWidget, reason: 'long enough to be read');

    await t.pump(const Duration(seconds: 2));
    await t.pump(const Duration(milliseconds: 600)); // its exit
    expect(notice, findsNothing, reason: 'nobody has to dismiss it');
  });

  testWidgets('a long message stays on one line, cut with an ellipsis', (
    t,
  ) async {
    await show(t, long);

    final text = t.widget<Text>(
      find.descendant(of: notice, matching: find.text(long)),
    );
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    final paragraph = t.renderObject<RenderParagraph>(
      find.descendant(of: notice, matching: find.text(long)),
    );
    expect(paragraph.didExceedMaxLines, isTrue, reason: 'it really was cut');
    expect(t.takeException(), isNull, reason: 'no overflow stripes');
    // The whole message still reaches a screen reader.
    expect(t.getSemantics(notice).label, contains(long));
    await drainNotice(t);
  });

  testWidgets('an error looks different from a success', (t) async {
    IconData? iconOf() => t
        .widget<Icon>(find.descendant(of: notice, matching: find.byType(Icon)))
        .icon;
    await show(t, 'Saved');
    final success = iconOf();
    await drainNotice(t);

    await show(t, 'Could not save', isError: true);
    final error = iconOf();
    await drainNotice(t);

    expect(error, isNotNull);
    expect(success, isNotNull);
    expect(error, isNot(success), reason: 'danger icon vs brand check');
  });
}
