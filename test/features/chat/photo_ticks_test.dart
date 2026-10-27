// PhotoTicks, from its contract: ticks by id in tick order, at most
// ExternalPicker.maxAttachments (the 11th shows attachLimit and changes
// nothing), a haptic click on a new tick.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/presentation/photo_ticks.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/external_picker.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/l10n/app_localizations.dart';

void main() {
  Future<BuildContext> pumpContext(WidgetTester tester) async {
    BuildContext? ctx;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pump(); // ensure context is ready
    return ctx!;
  }

  testWidgets('1. starts empty', (WidgetTester tester) async {
    final ticks = PhotoTicks();
    expect(ticks.value, isEmpty);
  });

  testWidgets('2. toggle adds a photo; order preserved', (
    WidgetTester tester,
  ) async {
    final ctx = await pumpContext(tester);
    final ticks = PhotoTicks();
    final p3 = GalleryPhoto('p3');
    final p1 = GalleryPhoto('p1');
    ticks.toggle(ctx, p3);
    await tester.pump();
    ticks.toggle(ctx, p1);
    await tester.pump();
    expect(ticks.value.map((p) => p.id).toList(), ['p3', 'p1']);
  });

  testWidgets(
    '3. toggling an already ticked photo removes it; same id unticks',
    (WidgetTester tester) async {
      final ctx = await pumpContext(tester);
      final ticks = PhotoTicks();
      final p1 = GalleryPhoto('p1');
      final p2 = GalleryPhoto('p1'); // same id
      final p3 = GalleryPhoto('p3');
      ticks.toggle(ctx, p1);
      await tester.pump();
      ticks.toggle(ctx, p2);
      await tester.pump();
      expect(ticks.value, isEmpty);
      final p4 = GalleryPhoto('p4');
      ticks.toggle(ctx, p3);
      ticks.toggle(ctx, p1);
      ticks.toggle(ctx, p4);
      await tester.pump();
      ticks.toggle(ctx, p2);
      await tester.pump();
      expect(ticks.value.map((p) => p.id).toList(), ['p3', 'p4']);
    },
  );

  testWidgets('4. listeners are notified on every add and remove', (
    WidgetTester tester,
  ) async {
    final ctx = await pumpContext(tester);
    final ticks = PhotoTicks();
    int count = 0;
    ticks.addListener(() => count++);
    final p1 = GalleryPhoto('p1');
    ticks.toggle(ctx, p1);
    await tester.pump();
    expect(count, 1);
    ticks.toggle(ctx, p1);
    await tester.pump();
    expect(count, 2);
  });

  testWidgets(
    '5. 10 ticks allowed; 11th shows notice and does not change value',
    (WidgetTester tester) async {
      final ctx = await pumpContext(tester);
      final ticks = PhotoTicks();
      final photos = List.generate(
        ExternalPicker.maxAttachments,
        (i) => GalleryPhoto('p$i'),
      );
      for (final p in photos) {
        ticks.toggle(ctx, p);
        await tester.pump();
      }
      expect(ticks.value.length, ExternalPicker.maxAttachments);
      expect(find.byType(SisNotice), findsNothing);

      var notified = 0;
      ticks.addListener(() => notified++);
      final p11 = GalleryPhoto('p10');
      ticks.toggle(ctx, p11);
      await tester.pump();
      expect(ticks.value.length, ExternalPicker.maxAttachments);
      expect(find.byType(SisNotice), findsOneWidget);
      final notice = tester.widget<SisNotice>(find.byType(SisNotice));
      expect(notice.message, contains('10'));
      expect(notice.isError, false);
      expect(notified, 0, reason: 'a refused tick changed the value');
      expect(ticks.value.map((p) => p.id), [for (final p in photos) p.id]);

      // untick one and tick the 11th again
      ticks.toggle(ctx, photos[0]); // untick first
      await tester.pump();
      expect(ticks.value.length, ExternalPicker.maxAttachments - 1);
      ticks.toggle(ctx, p11); // tick 11th again
      await tester.pump();
      expect(ticks.value.length, ExternalPicker.maxAttachments);
      expect(ticks.value.map((p) => p.id).contains('p10'), true);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('6. new tick triggers HapticFeedback.selectionClick', (
    WidgetTester tester,
  ) async {
    final ctx = await pumpContext(tester);
    final ticks = PhotoTicks();
    final log = <MethodCall>[];

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        log.add(call);
        return null;
      },
    );

    final p1 = GalleryPhoto('p1');
    ticks.toggle(ctx, p1);
    await tester.pump();
    expect(
      log.any(
        (call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.selectionClick',
      ),
      true,
    );

    final initialLogLength = log.length;
    ticks.toggle(ctx, p1); // untick
    await tester.pump();
    expect(log.length, initialLogLength); // no new haptic call
  });
}
