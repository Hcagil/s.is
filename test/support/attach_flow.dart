// The 0.30.10 paperclip flow, from its contract: the paperclip opens the
// photo grid straight away (no menu in between); a tap on a photo ticks it;
// "Send N photos" (sheet-send) loads the ticked photos and opens the preview
// page; the preview page's round Send (preview-send) is what sends. Camera
// and "Gallery" (sheet-from-app) also land on the preview page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Finder key(String k) => find.byKey(ValueKey(k));

Future<void> frames(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Taps the paperclip and lets the grid rise.
Future<void> openGrid(WidgetTester t) async {
  await t.tap(key('composer-attach'));
  await t.pumpAndSettle();
}

/// Ticks each of [ids] in the open grid.
Future<void> tick(WidgetTester t, List<String> ids) async {
  for (final id in ids) {
    await t.ensureVisible(key('sheet-photo-$id'));
    await t.pump();
    await t.tap(key('sheet-photo-$id'));
    await t.pump();
  }
}

/// Taps "Send N photos" and lets the photos load onto the preview page.
Future<void> sendTicked(WidgetTester t) async {
  await t.tap(key('sheet-send'));
  await frames(t);
}

/// The text the preview page's caption field holds.
String previewCaption(WidgetTester t) => t
    .widget<EditableText>(
      find.descendant(
        of: key('preview-caption'),
        matching: find.byType(EditableText),
        matchRoot: true,
      ),
    )
    .controller
    .text;

/// Taps the preview page's Send and lets the sends run, without letting a
/// notice's timer run out.
Future<void> previewSend(WidgetTester t) async {
  expect(key('preview-page'), findsOneWidget, reason: 'no preview page');
  await t.tap(key('preview-send'));
  await frames(t);
}

/// Ticks [ids], sends them to the preview, sends from there, and lets the
/// uploads and their pictures settle.
Future<void> sendFromGrid(WidgetTester t, List<String> ids) async {
  await openGrid(t);
  await tick(t, ids);
  await sendTicked(t);
  await previewSend(t);
  await settleImages(t);
}
