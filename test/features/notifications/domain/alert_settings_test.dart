import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';

void main() {
  group('AlertChoice', () {
    test('resolve with fallback true', () {
      expect(AlertChoice.byDefault.resolve(true), true);
      expect(AlertChoice.on.resolve(true), true);
      expect(AlertChoice.off.resolve(true), false);
    });

    test('resolve with fallback false', () {
      expect(AlertChoice.byDefault.resolve(false), false);
      expect(AlertChoice.on.resolve(false), true);
      expect(AlertChoice.off.resolve(false), false);
    });
  });

  group('AlertDefaults', () {
    final defaults = AlertDefaults(
      sound: false,
      tone: 'uri1',
      toneName: 'name1',
      vibration: false,
    );

    test('copyWith changes only specified fields', () {
      final copy = defaults.copyWith(sound: true);
      expect(copy.sound, true);
      expect(copy.vibration, defaults.vibration);
      expect(copy.tone, defaults.tone);
      expect(copy.toneName, defaults.toneName);
    });

    test('withTone replaces tone and toneName', () {
      final withTone = defaults.withTone('uri2', 'name2');
      expect(withTone.tone, 'uri2');
      expect(withTone.toneName, 'name2');
      expect(withTone.sound, defaults.sound);
      expect(withTone.vibration, defaults.vibration);
    });

    test('withTone(null, null) returns system default tone', () {
      final system = defaults.withTone(null, null);
      expect(system.tone, null);
      expect(system.toneName, null);
      expect(system.sound, defaults.sound);
      expect(system.vibration, defaults.vibration);
    });

    test('toJson/fromJson round-trip preserves all fields', () {
      final json = defaults.toJson();
      final roundTrip = AlertDefaults.fromJson(json);
      expect(roundTrip, defaults);
    });

    test('fromJson tolerant of missing keys', () {
      expect(AlertDefaults.fromJson({}), const AlertDefaults());
      // Only the keys that differ from the defaults' JSON: everything else
      // is missing and must come back as the default.
      Map<String, Object?> only(AlertDefaults d) {
        final base = const AlertDefaults().toJson();
        return {
          for (final e in d.toJson().entries)
            if (base[e.key] != e.value && e.value != null) e.key: e.value,
        };
      }

      for (final d in [
        const AlertDefaults(sound: false),
        const AlertDefaults(vibration: false),
        const AlertDefaults(tone: 'uri', toneName: 'name'),
      ]) {
        expect(AlertDefaults.fromJson(only(d)), d, reason: '${only(d)}');
      }
    });

    test('value equality', () {
      final a = const AlertDefaults(sound: true, vibration: true);
      final b = const AlertDefaults(sound: true, vibration: true);
      final c = const AlertDefaults(sound: false, vibration: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('ChatAlert', () {
    test('isDefault true only when both are byDefault', () {
      expect(const ChatAlert().isDefault, true);
      expect(
        const ChatAlert(
          sound: AlertChoice.byDefault,
          vibration: AlertChoice.on,
        ).isDefault,
        false,
      );
    });

    test('copyWith changes only specified fields', () {
      final original = const ChatAlert();
      final copy = original.copyWith(sound: AlertChoice.on);
      expect(copy.sound, AlertChoice.on);
      expect(copy.vibration, original.vibration);
    });

    test('fromJson tolerant of missing keys', () {
      expect(ChatAlert.fromJson({}), const ChatAlert());
      Map<String, Object?> only(ChatAlert c) {
        final base = const ChatAlert().toJson();
        return {
          for (final e in c.toJson().entries)
            if (base[e.key] != e.value) e.key: e.value,
        };
      }

      for (final c in [
        const ChatAlert(sound: AlertChoice.on),
        const ChatAlert(vibration: AlertChoice.off),
      ]) {
        expect(ChatAlert.fromJson(only(c)), c, reason: '${only(c)}');
      }
    });

    test('unknown choice names fallback to byDefault', () {
      final json = {
        for (final k in const ChatAlert(
          sound: AlertChoice.on,
          vibration: AlertChoice.on,
        ).toJson().keys)
          k: 'unknown',
      };
      expect(json, isNotEmpty);
      final alert = ChatAlert.fromJson(json);
      expect(alert.sound, AlertChoice.byDefault);
      expect(alert.vibration, AlertChoice.byDefault);
    });

    test('value equality', () {
      final a = const ChatAlert();
      final b = const ChatAlert();
      final c = const ChatAlert(sound: AlertChoice.on);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('EffectiveAlert', () {
    final defaults = AlertDefaults(
      sound: true,
      vibration: true,
      tone: 'uri',
      toneName: 'name',
    );

    test('default chat follows defaults', () {
      final effective = resolveAlert(defaults, const ChatAlert());
      expect(effective.sound, defaults.sound);
      expect(effective.vibration, defaults.vibration);
      expect(effective.tone, defaults.tone);
    });

    test('chat on overrides defaults off', () {
      final d = defaults.copyWith(sound: false, vibration: false);
      final c = const ChatAlert(
        sound: AlertChoice.on,
        vibration: AlertChoice.on,
      );
      final effective = resolveAlert(d, c);
      expect(effective.sound, true);
      expect(effective.vibration, true);
      expect(effective.tone, d.tone);
    });

    test('chat off overrides defaults on', () {
      final d = defaults.copyWith(sound: true, vibration: true);
      final c = const ChatAlert(
        sound: AlertChoice.off,
        vibration: AlertChoice.off,
      );
      final effective = resolveAlert(d, c);
      expect(effective.sound, false);
      expect(effective.vibration, false);
      expect(effective.tone, null);
    });

    test('sound off => tone null even if defaults have tone', () {
      final d = defaults.copyWith(sound: true);
      final c = const ChatAlert(sound: AlertChoice.off);
      final effective = resolveAlert(d, c);
      expect(effective.sound, false);
      expect(effective.tone, null);
    });

    test('chat sound on with defaults sound off => tone = defaults.tone', () {
      final d = defaults.copyWith(sound: false);
      final c = const ChatAlert(sound: AlertChoice.on);
      final effective = resolveAlert(d, c);
      expect(effective.sound, true);
      expect(effective.tone, d.tone);
    });
  });

  group('alertChannelId', () {
    final defaults = AlertDefaults(sound: true, vibration: true, tone: 'uri');

    test('matches expected pattern', () {
      final a = resolveAlert(defaults, const ChatAlert());
      final id = alertChannelId(a);
      expect(id, matches(RegExp(r'^msg-[0-9a-f]+-v[01]$')));
    });

    test('deterministic for same settings', () {
      final a1 = resolveAlert(defaults, const ChatAlert());
      final a2 = resolveAlert(defaults, const ChatAlert());
      expect(alertChannelId(a1), alertChannelId(a2));
    });

    test('different tones produce different ids', () {
      final d1 = defaults.withTone('uri1', 'One');
      final d2 = defaults.withTone('uri2', 'Two');
      final a1 = resolveAlert(d1, const ChatAlert());
      final a2 = resolveAlert(d2, const ChatAlert());
      expect(alertChannelId(a1), isNot(alertChannelId(a2)));
    });

    test('vibration changes only suffix', () {
      final d = defaults.copyWith(vibration: true);
      final aOn = resolveAlert(d, const ChatAlert());
      final aOff = resolveAlert(
        d.copyWith(vibration: false),
        const ChatAlert(),
      );
      final idOn = alertChannelId(aOn);
      final idOff = alertChannelId(aOff);
      expect(idOn, endsWith('-v1'));
      expect(idOff, endsWith('-v0'));
      expect(
        idOn.replaceAll(RegExp(r'-v[01]$'), ''),
        idOff.replaceAll(RegExp(r'-v[01]$'), ''),
      );
    });

    test('sound false => msg-off-vX', () {
      final d = defaults.copyWith(sound: false);
      final a = resolveAlert(d, const ChatAlert());
      final id = alertChannelId(a);
      expect(id, startsWith('msg-off-v'));
      expect(id, endsWith('-v${a.vibration ? 1 : 0}'));
    });

    test('sound true and tone null => msg-sys-vX', () {
      final d = defaults.withTone(null, null);
      final a = resolveAlert(d, const ChatAlert());
      final id = alertChannelId(a);
      expect(id, startsWith('msg-sys-v'));
      expect(id, endsWith('-v${a.vibration ? 1 : 0}'));
    });

    test('sound true and tone non-null => msg-<hash>-vX', () {
      final d = defaults.withTone('customUri', 'Custom');
      final a = resolveAlert(d, const ChatAlert());
      final id = alertChannelId(a);
      expect(id, startsWith('msg-'));
      expect(id, endsWith('-v${a.vibration ? 1 : 0}'));
      final hashPart = id.substring(
        4,
        id.length - 3,
      ); // remove 'msg-' and '-vX'
      expect(hashPart, matches(RegExp(r'^[0-9a-f]+$')));
    });
  });

  group('alertChannelName', () {
    final defaults = AlertDefaults(sound: true, vibration: true, tone: 'uri');

    test('sound false => Messages (silent)', () {
      final d = defaults.copyWith(sound: false);
      final a = resolveAlert(d, const ChatAlert());
      expect(alertChannelName(a), 'Messages (silent)');
    });

    test('sound true and tone null => Messages', () {
      final d = defaults.withTone(null, null);
      final a = resolveAlert(d, const ChatAlert());
      expect(alertChannelName(a), 'Messages');
    });

    test('sound true and tone set => Messages (custom tone)', () {
      final d = defaults.withTone('customUri', 'Custom');
      final a = resolveAlert(d, const ChatAlert());
      expect(alertChannelName(a), 'Messages (custom tone)');
    });

    test('no vibration appends ", no vibration"', () {
      final d = defaults.withTone(null, null).copyWith(vibration: false);
      final a = resolveAlert(d, const ChatAlert());
      expect(alertChannelName(a), 'Messages, no vibration');
    });

    test('silent + no vibration', () {
      final d = defaults.copyWith(sound: false, vibration: false);
      final a = resolveAlert(d, const ChatAlert());
      expect(alertChannelName(a), 'Messages (silent), no vibration');
    });
  });

  group('usedAlertChannelIds', () {
    final defaults = AlertDefaults(sound: true, vibration: true, tone: 'uri');

    test('empty chats => only defaults id', () {
      final ids = usedAlertChannelIds(defaults, {});
      expect(ids.length, 1);
      expect(
        ids,
        contains(alertChannelId(resolveAlert(defaults, const ChatAlert()))),
      );
    });

    test('duplicate effective settings => one extra id', () {
      final chat1 = const ChatAlert(sound: AlertChoice.off);
      final chat2 = const ChatAlert(sound: AlertChoice.off);
      final ids = usedAlertChannelIds(defaults, {
        'chat1': chat1,
        'chat2': chat2,
      });
      expect(ids, {
        alertChannelId(resolveAlert(defaults, const ChatAlert())),
        'msg-off-v1',
      });
    });

    test('default chat adds nothing', () {
      final ids = usedAlertChannelIds(defaults, {'default': const ChatAlert()});
      expect(ids.length, 1);
      expect(
        ids,
        contains(alertChannelId(resolveAlert(defaults, const ChatAlert()))),
      );
    });
  });

  // Added by review: what the draft left loose.
  group('exact contract values', () {
    test('AlertDefaults() is sound on, system tone, vibration on', () {
      const d = AlertDefaults();
      expect(d.sound, isTrue);
      expect(d.tone, isNull);
      expect(d.toneName, isNull);
      expect(d.vibration, isTrue);
    });

    test('ChatAlert() is Default/Default', () {
      expect(const ChatAlert().sound, AlertChoice.byDefault);
      expect(const ChatAlert().vibration, AlertChoice.byDefault);
      expect(const ChatAlert(sound: AlertChoice.off).isDefault, isFalse);
    });

    test('AlertDefaults equality looks at every field', () {
      const base = AlertDefaults(tone: 't', toneName: 'n');
      expect(base, const AlertDefaults(tone: 't', toneName: 'n'));
      expect(base, isNot(base.copyWith(sound: false)));
      expect(base, isNot(base.copyWith(vibration: false)));
      expect(base, isNot(base.withTone('t2', 'n')));
      expect(base, isNot(base.withTone('t', 'n2')));
    });

    test('ChatAlert and EffectiveAlert equality look at every field', () {
      expect(
        const ChatAlert(vibration: AlertChoice.off),
        isNot(const ChatAlert()),
      );
      const e = EffectiveAlert(sound: true, tone: 't', vibration: true);
      expect(e, const EffectiveAlert(sound: true, tone: 't', vibration: true));
      expect(
        e.hashCode,
        const EffectiveAlert(sound: true, tone: 't', vibration: true).hashCode,
      );
      expect(
        e,
        isNot(const EffectiveAlert(sound: false, tone: 't', vibration: true)),
      );
      expect(
        e,
        isNot(const EffectiveAlert(sound: true, tone: 'u', vibration: true)),
      );
      expect(
        e,
        isNot(const EffectiveAlert(sound: true, tone: 't', vibration: false)),
      );
    });

    test('AlertDefaults.fromJson falls back per missing key', () {
      const full = AlertDefaults(
        sound: false,
        tone: 't',
        toneName: 'n',
        vibration: false,
      );
      final json = full.toJson();
      for (final key in json.keys) {
        final partial = Map<String, Object?>.of(json)..remove(key);
        final back = AlertDefaults.fromJson(partial);
        expect(back, isNot(full), reason: 'dropping $key changed nothing');
      }
    });

    test('ChatAlert JSON round trip keeps both choices', () {
      for (final s in AlertChoice.values) {
        for (final v in AlertChoice.values) {
          final c = ChatAlert(sound: s, vibration: v);
          expect(ChatAlert.fromJson(c.toJson()), c);
        }
      }
    });

    test('channel ids for the fixed combinations', () {
      expect(
        alertChannelId(
          const EffectiveAlert(sound: false, tone: null, vibration: false),
        ),
        'msg-off-v0',
      );
      expect(
        alertChannelId(
          const EffectiveAlert(sound: false, tone: 'x', vibration: true),
        ),
        'msg-off-v1',
      );
      expect(
        alertChannelId(
          const EffectiveAlert(sound: true, tone: null, vibration: true),
        ),
        'msg-sys-v1',
      );
      expect(
        alertChannelId(
          const EffectiveAlert(sound: true, tone: null, vibration: false),
        ),
        'msg-sys-v0',
      );
      expect(alertChannelPrefix, 'msg-');
    });

    test('a custom tone id is the FNV-1a hex of the tone uri', () {
      const uri = 'content://media/internal/audio/media/42';
      final id = alertChannelId(
        const EffectiveAlert(sound: true, tone: uri, vibration: true),
      );
      final hex = id.substring(4, id.length - 3);
      final bytes = uri.codeUnits;
      var h32 = 0x811c9dc5;
      for (final b in bytes) {
        h32 = ((h32 ^ b) * 0x01000193) & 0xffffffff;
      }
      var h64 = 0xcbf29ce484222325;
      for (final b in bytes) {
        h64 = (h64 ^ b) * 0x100000001b3;
      }
      final ok = {
        h32.toRadixString(16),
        h32.toRadixString(16).padLeft(8, '0'),
        h64.toUnsigned(64).toRadixString(16),
        h64.toUnsigned(64).toRadixString(16).padLeft(16, '0'),
      };
      expect(ok, contains(hex));
    });

    test('custom tone with vibration off names it', () {
      expect(
        alertChannelName(
          const EffectiveAlert(sound: true, tone: 't', vibration: false),
        ),
        'Messages (custom tone), no vibration',
      );
    });

    test(
      'used ids include a chat whose tone differs only through sound on',
      () {
        const d = AlertDefaults(sound: false, tone: 't', toneName: 'T');
        final ids = usedAlertChannelIds(d, {
          'a': const ChatAlert(sound: AlertChoice.on),
          'b': const ChatAlert(vibration: AlertChoice.off),
        });
        expect(ids, {
          'msg-off-v1',
          alertChannelId(
            const EffectiveAlert(sound: true, tone: 't', vibration: true),
          ),
          'msg-off-v0',
        });
      },
    );
  });
}
