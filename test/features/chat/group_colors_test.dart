import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/conversation.dart';

/// Computes the WCAG 2.x contrast ratio between two 32‑bit ARGB colours.
double contrastRatio(int color1, int color2) {
  // Extract RGB components (ignore alpha).
  final r1 = (color1 >> 16) & 0xFF;
  final g1 = (color1 >> 8) & 0xFF;
  final b1 = color1 & 0xFF;
  final r2 = (color2 >> 16) & 0xFF;
  final g2 = (color2 >> 8) & 0xFF;
  final b2 = color2 & 0xFF;

  double linear(int c) {
    final s = c / 255.0;
    return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  double luminance(int r, int g, int b) =>
      0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);

  final l1 = luminance(r1, g1, b1);
  final l2 = luminance(r2, g2, b2);
  final lMax = max(l1, l2);
  final lMin = min(l1, l2);
  return (lMax + 0.05) / (lMin + 0.05);
}

void main() {
  group('Group colour contract', () {
    test('groupColorSlots is 10', () {
      expect(groupColorSlots, equals(10));
    });

    test('Each theme has 10 distinct fully opaque colours', () {
      for (final dark in [false, true]) {
        final colors = <int>{};
        for (var i = 0; i < groupColorSlots; i++) {
          final c = groupColorArgb(i, dark: dark);
          expect(
            (c >> 24) & 0xFF,
            equals(0xFF),
            reason: 'Alpha not opaque for slot $i, dark=$dark',
          );
          colors.add(c);
        }
        expect(
          colors.length,
          equals(groupColorSlots),
          reason: 'Colours not distinct for dark=$dark',
        );
      }
    });

    test('Colours wrap modulo 10', () {
      for (var i = 0; i < groupColorSlots; i++) {
        final baseLight = groupColorArgb(i, dark: false);
        final baseDark = groupColorArgb(i, dark: true);
        expect(groupColorArgb(i + 10, dark: false), equals(baseLight));
        expect(groupColorArgb(i + 20, dark: false), equals(baseLight));
        expect(groupColorArgb(i + 10, dark: true), equals(baseDark));
        expect(groupColorArgb(i + 20, dark: true), equals(baseDark));
      }
    });

    test('Light and dark palettes differ', () {
      final light = List<int>.generate(
        groupColorSlots,
        (i) => groupColorArgb(i, dark: false),
      );
      final dark = List<int>.generate(
        groupColorSlots,
        (i) => groupColorArgb(i, dark: true),
      );
      expect(light, isNot(equals(dark)));
    });

    test('Contrast ratios meet WCAG 2.x thresholds', () {
      const white = 0xFFFFFFFF;
      const offWhite = 0xFFF5F4FA;
      const darkBackground = 0xFF1D1A42;

      for (var i = 0; i < groupColorSlots; i++) {
        final light = groupColorArgb(i, dark: false);
        final dark = groupColorArgb(i, dark: true);

        final ratioLightWhite = contrastRatio(light, white);
        expect(
          ratioLightWhite,
          greaterThanOrEqualTo(4.5),
          reason: 'Slot $i light vs white ratio $ratioLightWhite',
        );

        final ratioLightOffWhite = contrastRatio(light, offWhite);
        expect(
          ratioLightOffWhite,
          greaterThanOrEqualTo(4.5),
          reason: 'Slot $i light vs offWhite ratio $ratioLightOffWhite',
        );

        final ratioDarkBackground = contrastRatio(dark, darkBackground);
        expect(
          ratioDarkBackground,
          greaterThanOrEqualTo(4.5),
          reason: 'Slot $i dark vs darkBackground ratio $ratioDarkBackground',
        );
      }
    });

    test('Contrast helper sanity checks', () {
      const black = 0xFF000000;
      const white = 0xFFFFFFFF;
      final ratioBlackWhite = contrastRatio(black, white);
      expect(
        ratioBlackWhite,
        closeTo(21.0, 0.01),
        reason: 'Black vs white ratio $ratioBlackWhite',
      );

      final ratioWhiteWhite = contrastRatio(white, white);
      expect(
        ratioWhiteWhite,
        closeTo(1.0, 0.01),
        reason: 'White vs white ratio $ratioWhiteWhite',
      );
    });
  });

  group('GroupVoice JSON round‑trip', () {
    test('toJson/fromJson preserves name and slot', () {
      final voice = GroupVoice('Test Voice', 3);
      final json = voice.toJson();
      final roundTrip = GroupVoice.fromJson(json);
      expect(roundTrip.name, equals(voice.name));
      expect(roundTrip.slot, equals(voice.slot));
    });
  });

  group('Conversation JSON round‑trip', () {
    final senders = <String, GroupVoice>{
      'user1': GroupVoice('Alice', 1),
      'user2': GroupVoice('Bob', 2),
    };

    test('toJson -> fromJson retains senders', () {
      final conv = Conversation(
        id: 'conv1',
        title: 'Group Chat',
        senders: senders,
      );
      final jsonMap = conv.toJson();
      final jsonString = jsonEncode(jsonMap);
      final decodedMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final roundTrip = Conversation.fromJson(decodedMap);

      expect(roundTrip.id, equals(conv.id));
      expect(roundTrip.title, equals(conv.title));
      expect(roundTrip.senders.length, equals(senders.length));

      for (final key in senders.keys) {
        final original = senders[key]!;
        final round = roundTrip.senders[key]!;
        expect(round.name, equals(original.name));
        expect(round.slot, equals(original.slot));
      }
    });

    test('fromJson tolerates missing senders key', () {
      final conv = Conversation(
        id: 'conv2',
        title: 'No Senders',
        senders: senders,
      );
      final jsonMap = conv.toJson();
      final jsonString = jsonEncode(jsonMap);
      final decodedMap = jsonDecode(jsonString) as Map<String, dynamic>;
      decodedMap.remove('senders'); // simulate missing key
      final roundTrip = Conversation.fromJson(decodedMap);

      expect(roundTrip.id, equals(conv.id));
      expect(roundTrip.title, equals(conv.title));
      expect(roundTrip.senders.isEmpty, isTrue);
    });
  });
}
