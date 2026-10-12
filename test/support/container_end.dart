// A testWidgets that disposes the test's ProviderContainers at the end of the
// body. The binding checks for pending timers BEFORE addTearDown runs (so
// before ProviderContainer.test disposes itself), and the session controller
// keeps a periodic "was this phone replaced?" timer until it is disposed.
//
// Use: import flutter_test with `hide testWidgets`, import this file, and
// wrap each container in [track].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' as ft;

final _open = <ProviderContainer>[];

/// Disposes [c] when the current test body ends.
ProviderContainer track(ProviderContainer c) {
  _open.add(c);
  return c;
}

void testWidgets(String description, ft.WidgetTesterCallback body) =>
    ft.testWidgets(description, (t) async {
      try {
        await body(t);
      } finally {
        for (final c in _open) {
          c.dispose();
        }
        _open.clear();
      }
    });
