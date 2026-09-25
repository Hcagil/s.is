// SIS's own waits, from their contract in lib/app/loading.dart: the logo
// pulses -- except when the phone asks for reduced motion, when it holds
// still -- and replaces every Android spinner.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/loading.dart';

Widget host(Widget child, {bool reducedMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion),
    child: Scaffold(body: child),
  ),
);

void main() {
  group('SisLoadingLogo', () {
    testWidgets('pulses: it keeps asking for frames', (t) async {
      await t.pumpWidget(host(const Center(child: SisLoadingLogo())));
      await t.pump(const Duration(milliseconds: 100));
      final first = t.getRect(find.byType(SisLoadingLogo));

      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 100));
        expect(
          t.binding.hasScheduledFrame,
          isTrue,
          reason: 'a pulse is an animation that never settles',
        );
      }
      expect(
        t.getRect(find.byType(SisLoadingLogo)),
        first,
        reason: 'the pulse must not move the layout around it',
      );
    });

    testWidgets('holds still when the phone asks for reduced motion', (
      t,
    ) async {
      await t.pumpWidget(
        host(const Center(child: SisLoadingLogo()), reducedMotion: true),
      );

      // Settles: nothing is animating.
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
      expect(find.byType(SisLoadingLogo), findsOneWidget);
    });

    testWidgets('is the size it is given (72 by default)', (t) async {
      await t.pumpWidget(
        host(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SisLoadingLogo(key: ValueKey('default')),
              SisLoadingLogo(key: ValueKey('small'), size: 40),
            ],
          ),
          reducedMotion: true,
        ),
      );

      expect(
        t.getSize(find.byKey(const ValueKey('default'))),
        const Size(72, 72),
      );
      expect(
        t.getSize(find.byKey(const ValueKey('small'))),
        const Size(40, 40),
      );
    });
  });

  testWidgets('SisFullScreenLoader centres the logo on the screen', (t) async {
    await t.pumpWidget(host(const SisFullScreenLoader(), reducedMotion: true));

    expect(find.byType(SisLoadingLogo), findsOneWidget);
    final scaffold = t.getRect(find.byType(Scaffold).first);
    expect(t.getCenter(find.byType(SisLoadingLogo)), scaffold.center);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('SisProgressLine is a thin line across the width', (t) async {
    await t.pumpWidget(
      host(const Column(children: [SisProgressLine()]), reducedMotion: true),
    );
    await t.pump(const Duration(milliseconds: 100));

    final size = t.getSize(find.byType(SisProgressLine));
    expect(size.width, t.getSize(find.byType(Scaffold)).width);
    expect(size.height, inInclusiveRange(1, 8), reason: 'a line, not a bar');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
