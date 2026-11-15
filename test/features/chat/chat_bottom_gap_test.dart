// This test reproduces the iPhone chat bug where the home-indicator inset
// adds an extra blank band above the input bar when the keyboard is closed.
// The inset must be applied only once, below the bar, and never above it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/chat_launcher.dart';

Future<void> safeBottom(WidgetTester t, double logical) async {
  t.view.padding = FakeViewPadding(bottom: logical * t.view.devicePixelRatio);
  t.view.viewPadding = FakeViewPadding(
    bottom: logical * t.view.devicePixelRatio,
  );
  t.view.viewInsets = FakeViewPadding.zero;
  await t.pumpAndSettle();
}

void main() {
  testWidgets('iPhone: the safe-area inset adds no space above the input bar', (
    WidgetTester t,
  ) async {
    await openChat(t, messages: manyMessages(3));
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewPadding);
    addTearDown(t.view.resetViewInsets);

    await safeBottom(t, 0);
    final above0 = t.getTopLeft(composer).dy - t.getBottomLeft(bubble('m2')).dy;
    final below0 = screenHeight(t) - t.getBottomLeft(composer).dy;

    await safeBottom(t, 34);
    final above34 =
        t.getTopLeft(composer).dy - t.getBottomLeft(bubble('m2')).dy;
    final below34 = screenHeight(t) - t.getBottomLeft(composer).dy;

    expect(
      above34,
      closeTo(above0, 0.5),
      reason: 'above: inset 0 -> $above0, inset 34 -> $above34',
    );
    expect(
      below34 - below0,
      closeTo(34, 0.5),
      reason: 'below: inset 0 -> $below0, inset 34 -> $below34',
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'Android: the safe-area inset adds no space above the input bar',
    (WidgetTester t) async {
      await openChat(t, messages: manyMessages(3));
      addTearDown(t.view.resetPadding);
      addTearDown(t.view.resetViewPadding);
      addTearDown(t.view.resetViewInsets);

      await safeBottom(t, 0);
      final above0 =
          t.getTopLeft(composer).dy - t.getBottomLeft(bubble('m2')).dy;
      final below0 = screenHeight(t) - t.getBottomLeft(composer).dy;

      await safeBottom(t, 24);
      final above24 =
          t.getTopLeft(composer).dy - t.getBottomLeft(bubble('m2')).dy;
      final below24 = screenHeight(t) - t.getBottomLeft(composer).dy;

      expect(
        above24,
        closeTo(above0, 0.5),
        reason: 'above: inset 0 -> $above0, inset 24 -> $above24',
      );
      expect(
        below24 - below0,
        closeTo(24, 0.5),
        reason: 'below: inset 0 -> $below0, inset 24 -> $below24',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
