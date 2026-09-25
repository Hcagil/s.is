// Finders and waits for SIS's own UI: the pulsing logo and brand line that
// replace Android's spinners, and the notice pill that replaces SnackBar.
import 'dart:ui' show CheckedState, SemanticsFlags, Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/app/notice.dart';

/// SIS's own waits -- the pulsing logo or the brand line. The only waits
/// allowed on screen.
final sisWait = find.byWidgetPredicate(
  (w) => w is SisLoadingLogo || w is SisProgressLine,
);

/// The notice pill that reports a result.
final notice = find.byType(SisNotice);

/// A notice whose text contains [text].
Finder noticeSaying(String text) =>
    find.descendant(of: notice, matching: find.textContaining(text));

/// Lets a notice's ~2 s timer run out (and its exit finish) so it does not
/// outlive the test.
Future<void> drainNotice(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(seconds: 1));
}

SemanticsFlags _flags(WidgetTester t, Finder f) =>
    t.getSemantics(f).getSemanticsData().flagsCollection;

/// Whether the switch at [f] reads as on to a screen reader -- the contract
/// SisSwitch keeps. Fails if [f] is not announced as a toggle at all.
bool toggledOn(WidgetTester t, Finder f) {
  final toggled = _flags(t, f).isToggled;
  expect(toggled, isNot(Tristate.none), reason: '$f is not a toggle');
  return toggled == Tristate.isTrue;
}

/// Whether the [SisSwitch] at or under [f] (a switch, or a settings row
/// holding one) reads as on to a screen reader.
bool switchedOn(WidgetTester t, Finder f) => toggledOn(
  t,
  find.descendant(of: f, matching: find.byType(SisSwitch), matchRoot: true),
);

/// Whether the choice at [f] reads as the selected one of its group to a
/// screen reader. Fails if [f] is not announced as one of a group.
bool choiceSelected(WidgetTester t, Finder f) {
  final flags = _flags(t, f);
  expect(
    flags.isInMutuallyExclusiveGroup,
    isTrue,
    reason: '$f is not announced as one of a single-choice group',
  );
  return flags.isSelected == Tristate.isTrue ||
      flags.isChecked == CheckedState.isTrue;
}
