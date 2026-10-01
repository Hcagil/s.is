// Home's "New group" / "New chat" buttons (new-group, new-chat), written from
// the 0.30.3 contract: on a narrow phone (320 and 360 dp wide, no keyboard,
// SIS's theme) nothing overflows, both labels are whole and on screen and the
// buttons do not overlap; at 411 dp they sit side by side.
//
// The whole app as main.dart mounts it (World from avatar_widgets_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../profile/avatar_widgets_test.dart' show World, byKey, settle;

Future<Size> homeAt(WidgetTester t, double widthDp) async {
  const dpr = 2.625;
  final size = Size(widthDp, 640);
  t.view.physicalSize = size * dpr;
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.reset);
  await t.pumpWidget(World().app());
  await settle(t);
  expect(t.takeException(), isNull, reason: 'overflow at $widthDp dp');
  return size;
}

Rect labelRect(WidgetTester t, String key, String label) {
  final text = find.descendant(of: byKey(key), matching: find.text(label));
  expect(text, findsOneWidget, reason: '$label is missing');
  final para = t.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText)),
  );
  expect(para.didExceedMaxLines, isFalse, reason: '$label is cut short');
  expect(
    para.size.width + 0.5,
    greaterThanOrEqualTo(para.getMaxIntrinsicWidth(double.infinity)),
    reason: '$label is clipped',
  );
  return t.getRect(text);
}

void main() {
  for (final width in [320.0, 360.0, 411.0]) {
    testWidgets('at $width dp: no overflow, both labels whole on screen, '
        'no overlap', (t) async {
      final screen = Offset.zero & await homeAt(t, width);
      final group = t.getRect(byKey('new-group'));
      final chat = t.getRect(byKey('new-chat'));
      for (final (key, label) in [
        ('new-group', 'New group'),
        ('new-chat', 'New chat'),
      ]) {
        final r = labelRect(t, key, label);
        expect(
          screen.contains(r.topLeft) && screen.contains(r.bottomRight),
          isTrue,
          reason: '$label is off screen at $width dp: $r',
        );
      }
      for (final r in [group, chat]) {
        expect(
          screen.contains(r.topLeft) && screen.contains(r.bottomRight),
          isTrue,
          reason: 'a button is off screen at $width dp: $r',
        );
      }
      expect(
        group.intersect(chat).isEmpty ||
            group.intersect(chat).width <= 0 ||
            group.intersect(chat).height <= 0,
        isTrue,
        reason: 'the buttons overlap at $width dp: $group / $chat',
      );
      if (width == 411) {
        expect(group.center.dy, closeTo(chat.center.dy, 0.5));
        expect(group.right, lessThanOrEqualTo(chat.left));
      }
    });
  }
}
