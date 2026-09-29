// AlertController against fakes of its two ports, written from the
// AlertStore / TonePicker interfaces (not from the controller). The fakes
// behave like the real ones where it matters: the store answers after a
// delay and keeps only non-default chats; the picker can be cancelled, can
// pick the system default, or can fail.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/application/alert_controller.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';

class SlowStore implements AlertStore {
  SlowStore({
    this.defaults = const AlertDefaults(),
    Map<String, ChatAlert>? chats,
  }) : chats = {...?chats};

  AlertDefaults defaults;
  final Map<String, ChatAlert> chats;
  final saves = <Object>[];
  static const _latency = Duration(milliseconds: 5);

  @override
  Future<AlertDefaults> loadDefaults() async {
    await Future<void>.delayed(_latency);
    return defaults;
  }

  @override
  Future<Map<String, ChatAlert>> loadChats() async {
    await Future<void>.delayed(_latency);
    return Map.of(chats);
  }

  @override
  Future<void> saveDefaults(AlertDefaults d) async {
    await Future<void>.delayed(_latency);
    saves.add(d);
    defaults = d;
  }

  @override
  Future<void> saveChat(String conversationId, ChatAlert c) async {
    await Future<void>.delayed(_latency);
    saves.add((conversationId, c));
    if (c.isDefault) {
      chats.remove(conversationId);
    } else {
      chats[conversationId] = c;
    }
  }
}

class ScriptedPicker implements TonePicker {
  ScriptedPicker(this.reply);
  FutureOr<PickedTone?> Function() reply;
  final asked = <String?>[];

  @override
  Future<PickedTone?> pick(String? currentTone) async {
    asked.add(currentTone);
    return reply();
  }
}

void main() {
  late SlowStore store;
  late ScriptedPicker picker;
  late ProviderContainer c;

  ProviderContainer make() => ProviderContainer(
    overrides: [
      alertStoreProvider.overrideWithValue(store),
      tonePickerProvider.overrideWithValue(picker),
    ],
  );

  Future<AlertPrefs> prefs() => c.read(alertPrefsProvider.future);
  AlertController ctl() => c.read(alertPrefsProvider.notifier);

  setUp(() {
    store = SlowStore();
    picker = ScriptedPicker(() => null);
    c = make();
  });
  tearDown(() => c.dispose());

  test('the ports are not wired by default', () {
    final bare = ProviderContainer();
    addTearDown(bare.dispose);
    expect(() => bare.read(alertStoreProvider), throwsA(anything));
    expect(() => bare.read(tonePickerProvider), throwsA(anything));
  });

  test('loads the saved defaults and chats (needs no account)', () async {
    c.dispose();
    const saved = AlertDefaults(sound: false, tone: 't', toneName: 'T');
    store = SlowStore(
      defaults: saved,
      chats: {'c1': const ChatAlert(vibration: AlertChoice.off)},
    );
    c = make();

    expect(c.read(alertPrefsProvider).isLoading, isTrue);
    final p = await prefs();
    expect(p.defaults, saved);
    expect(p.chats, {'c1': const ChatAlert(vibration: AlertChoice.off)});
    expect(p.chat('c1'), const ChatAlert(vibration: AlertChoice.off));
    expect(p.chat('unknown'), const ChatAlert(), reason: 'Default/Default');
  });

  test('setDefaults saves and updates state, keeping chat overrides', () async {
    await prefs();
    await ctl().setChat('c1', const ChatAlert(sound: AlertChoice.on));

    const next = AlertDefaults(sound: false, vibration: false);
    await ctl().setDefaults(next);

    final p = await prefs();
    expect(p.defaults, next);
    expect(p.chat('c1'), const ChatAlert(sound: AlertChoice.on));
    expect(store.defaults, next);
    expect(store.saves.last, next);
  });

  test(
    'setChat saves and updates state; back to Default drops the entry',
    () async {
      await prefs();
      await ctl().setChat('c1', const ChatAlert(sound: AlertChoice.off));
      expect((await prefs()).chats, {
        'c1': const ChatAlert(sound: AlertChoice.off),
      });
      expect(store.chats, {'c1': const ChatAlert(sound: AlertChoice.off)});

      await ctl().setChat('c1', const ChatAlert());
      final p = await prefs();
      expect(p.chats, isEmpty, reason: 'a Default chat is not an override');
      expect(p.chat('c1'), const ChatAlert());
      expect(store.saves.last, ('c1', const ChatAlert()));
      expect(store.chats, isEmpty);
    },
  );

  test('setChat for one chat leaves the others and the defaults', () async {
    await prefs();
    await ctl().setChat('c1', const ChatAlert(sound: AlertChoice.off));
    await ctl().setChat('c2', const ChatAlert(vibration: AlertChoice.on));
    await ctl().setChat('c1', const ChatAlert());

    final p = await prefs();
    expect(p.chats, {'c2': const ChatAlert(vibration: AlertChoice.on)});
    expect(p.defaults, const AlertDefaults());
  });

  group('pickTone', () {
    const start = AlertDefaults(
      sound: true,
      tone: 'content://tone/1',
      toneName: 'Old',
      vibration: false,
    );

    setUp(() {
      c.dispose();
      store = SlowStore(defaults: start);
      c = make();
    });

    test('asks with the current tone and saves the picked one', () async {
      await prefs();
      picker.reply = () =>
          const PickedTone(tone: 'content://tone/2', name: 'Bell');

      await ctl().pickTone();

      expect(picker.asked, ['content://tone/1']);
      final want = start.withTone('content://tone/2', 'Bell');
      expect((await prefs()).defaults, want);
      expect(store.defaults, want);
      expect(want.vibration, isFalse, reason: 'sound/vibration kept');
    });

    test('picking the system default stores no tone and no name', () async {
      await prefs();
      picker.reply = () =>
          const PickedTone(tone: null, name: 'Default (Pixie)');

      await ctl().pickTone();

      final d = (await prefs()).defaults;
      expect(d.tone, isNull);
      expect(
        d.toneName,
        isNull,
        reason: 'the subtitle then says System default',
      );
      expect(d.sound, isTrue);
      expect(d.vibration, isFalse);
      expect(store.defaults, d);
    });

    test('cancel changes nothing and saves nothing', () async {
      await prefs();
      picker.reply = () => null;

      await ctl().pickTone();

      expect(picker.asked, hasLength(1));
      expect((await prefs()).defaults, start);
      expect(store.saves, isEmpty);
    });

    test('a failing picker changes nothing and saves nothing', () async {
      await prefs();
      picker.reply = () => throw StateError('picker died');

      try {
        await ctl().pickTone();
      } catch (_) {
        // Whether the error surfaces is not in the contract; the state is.
      }

      expect((await prefs()).defaults, start);
      expect(store.saves, isEmpty);
    });
  });

  test('a new controller over the same store sees what was set', () async {
    await prefs();
    await ctl().setDefaults(const AlertDefaults(sound: false));
    await ctl().setChat('c1', const ChatAlert(sound: AlertChoice.on));
    c.dispose();

    c = make();
    final p = await prefs();
    expect(p.defaults, const AlertDefaults(sound: false));
    expect(p.chats, {'c1': const ChatAlert(sound: AlertChoice.on)});
  });
}
