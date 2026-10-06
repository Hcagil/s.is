// What each tick state LOOKS like (owner rule Q7), judged by the pixels the
// DeliveryTick paints, not by how it is built: a clock, one tick, two ticks
// (grey, in the rest colour), two ticks in blue. Four states, four different
// pictures; only "read" is blue; two ticks carry more ink than one.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/l10n/app_localizations.dart';

const rest = Color(0xFFFFFFFF);

/// RGBA pixels of [d] painted at 14 px on black, in the rest colour white.
Future<Uint8List> paint(WidgetTester t, Delivery d) async {
  final key = GlobalKey();
  await t.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: sisTheme(Brightness.light),
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFF000000),
            width: 20,
            height: 20,
            alignment: Alignment.center,
            child: DeliveryTick(delivery: d, color: rest),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await t.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

/// Pixels with any ink on the black ground.
int ink(Uint8List px) {
  var n = 0;
  for (var i = 0; i < px.length; i += 4) {
    if (px[i] + px[i + 1] + px[i + 2] > 90) n++;
  }
  return n;
}

/// Pixels clearly blue: blue well above red.
int blue(Uint8List px) {
  var n = 0;
  for (var i = 0; i < px.length; i += 4) {
    if (px[i + 2] > 90 && px[i + 2] - px[i] > 40) n++;
  }
  return n;
}

/// Tests draw icon glyphs as boxes unless the real icon font is loaded.
Future<void> loadMaterialIcons() async {
  final root = Platform.environment['FLUTTER_ROOT']!;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  final loader = FontLoader('MaterialIcons')
    ..addFont(file.readAsBytes().then(ByteData.sublistView));
  await loader.load();
}

void main() {
  setUpAll(loadMaterialIcons);

  testWidgets('four states, four pictures; only read is blue; two ticks '
      'carry more ink than one', (t) async {
    final px = {for (final d in Delivery.values) d: await paint(t, d)};
    for (final d in Delivery.values) {
      expect(ink(px[d]!), greaterThan(10), reason: '$d draws nothing');
    }
    for (final a in Delivery.values) {
      for (final b in Delivery.values) {
        if (a.index < b.index) {
          expect(
            listEquals(px[a], px[b]),
            isFalse,
            reason: '$a and $b look the same',
          );
        }
      }
    }
    expect(blue(px[Delivery.read]!), greaterThan(10), reason: 'read is blue');
    for (final d in [Delivery.pending, Delivery.sent, Delivery.delivered]) {
      expect(blue(px[d]!), 0, reason: '$d is not grey/rest colour');
    }
    expect(
      ink(px[Delivery.delivered]!),
      greaterThan(ink(px[Delivery.sent]!) * 1.3),
      reason: 'two ticks are not more than one',
    );
    expect(
      ink(px[Delivery.read]!),
      greaterThan(ink(px[Delivery.sent]!) * 1.3),
      reason: 'read is two ticks',
    );
  });
}
