// AlertRemoteSync against fakes of its two ports, written from the
// AlertStore / TonePicker interfaces (not from the controller). The fakes
// behave like the real ones where it matters: the store answers after a
// delay and keeps only non-default chats; the picker can be cancelled, can
// pick the system default, or can fail.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/notifications/application/alert_controller.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';

class Journal {
  final events = <String>[];
}

class JournalStore implements AlertStore {
  JournalStore({
    required this.journal,
    this.defaults = const AlertDefaults(),
    Map<String, ChatAlert>? chats,
  }) : chats = {...?chats};

  final Journal journal;
  AlertDefaults defaults;
  final Map<String, ChatAlert> chats;
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
    journal.events.add('store.saveDefaults');
    defaults = d;
  }

  @override
  Future<void> saveChat(String conversationId, ChatAlert c) async {
    await Future<void>.delayed(_latency);
    journal.events.add('store.saveChat:$conversationId');
    if (c.isDefault) {
      chats.remove(conversationId);
    } else {
      chats[conversationId] = c;
    }
  }
}

class FakeRemote implements AlertRemote {
  FakeRemote(this.journal);

  final Journal journal;
  Result<RemoteAlerts> loadResult = const Ok(RemoteAlerts(chats: {}));
  Result<void> saveResult = const Ok<void>(null);
  int loads = 0;
  final defaultsSaved = <(bool, bool)>[];
  final chatsSaved = <(String, ChatAlert)>[];
  static const _latency = Duration(milliseconds: 5);

  @override
  Future<Result<RemoteAlerts>> load() async {
    await Future<void>.delayed(_latency);
    loads++;
    journal.events.add('remote.load');
    return loadResult;
  }

  @override
  Future<Result<void>> saveDefaults({
    required bool sound,
    required bool vibration,
  }) async {
    await Future<void>.delayed(_latency);
    journal.events.add('remote.saveDefaults');
    if (saveResult is Ok) {
      defaultsSaved.add((sound, vibration));
    }
    return saveResult;
  }

  @override
  Future<Result<void>> saveChat(String conversationId, ChatAlert c) async {
    await Future<void>.delayed(_latency);
    journal.events.add('remote.saveChat:$conversationId');
    if (saveResult is Ok) {
      chatsSaved.add((conversationId, c));
    }
    return saveResult;
  }
}

class NoPicker implements TonePicker {
  @override
  Future<PickedTone?> pick(String? currentTone) async => null;
}

class Me extends CurrentUserId {
  Me(this.id);
  String? id;
  @override
  String? build() => id;
  void set(String? v) => state = v;
}

void main() {
  late Journal journal;
  late JournalStore store;
  late FakeRemote remote;
  late ProviderContainer c;

  ProviderContainer make({String? user = 'u1', bool withRemote = true}) {
    final container = ProviderContainer(
      overrides: [
        alertStoreProvider.overrideWithValue(store),
        tonePickerProvider.overrideWithValue(NoPicker()),
        currentUserIdProvider.overrideWith(() => Me(user)),
        if (withRemote) alertRemoteProvider.overrideWithValue(remote),
      ],
    );
    container.listen(alertPrefsProvider, (_, _) {});
    addTearDown(container.dispose);
    return container;
  }

  Future<AlertPrefs> prefs() => c.read(alertPrefsProvider.future);

  setUp(() {
    journal = Journal();
    store = JournalStore(journal: journal);
    remote = FakeRemote(journal);
    remote.loadResult = const Ok(
      RemoteAlerts(sound: true, vibration: true, chats: {}),
    );
    // c = make();  // removed to avoid leaking state between tests
  });

  test('setDefaults saves to the account first, then the phone', () async {
    c = make(); // added
    await prefs();
    journal.events.clear();
    final r = await c
        .read(alertPrefsProvider.notifier)
        .setDefaults(const AlertDefaults(sound: false, vibration: false));
    expect(r, isA<Ok<void>>());
    expect(journal.events, ['remote.saveDefaults', 'store.saveDefaults']);
    expect(remote.defaultsSaved, [(false, false)]);
    expect((await prefs()).defaults.sound, isFalse);
  });

  test('setChat saves to the account first, then the phone', () async {
    c = make(); // added
    await prefs();
    journal.events.clear();
    final r = await c
        .read(alertPrefsProvider.notifier)
        .setChat('c1', const ChatAlert(sound: AlertChoice.off));
    expect(r, isA<Ok<void>>());
    expect(journal.events, ['remote.saveChat:c1', 'store.saveChat:c1']);
    expect(remote.chatsSaved, [
      ('c1', const ChatAlert(sound: AlertChoice.off)),
    ]);
    expect((await prefs()).chat('c1'), const ChatAlert(sound: AlertChoice.off));
  });

  test(
    'an account failure keeps the old values and saves nothing on the phone',
    () async {
      remote.saveResult = const Err<void>(NetworkFailure('offline'));
      c = make();
      await prefs();
      journal.events.clear();
      final r1 = await c
          .read(alertPrefsProvider.notifier)
          .setDefaults(const AlertDefaults(sound: false));
      final r2 = await c
          .read(alertPrefsProvider.notifier)
          .setChat('c1', const ChatAlert(vibration: AlertChoice.on));
      expect(r1, isA<Err<void>>());
      expect(r2, isA<Err<void>>());
      expect(
        journal.events.where((e) => e.startsWith('store.')).isEmpty,
        isTrue,
      );
      expect((await prefs()).defaults, const AlertDefaults());
      expect((await prefs()).chats, isEmpty);
      expect(store.defaults, const AlertDefaults());
      expect(store.chats, isEmpty);
    },
  );

  test('start-up: the account overwrites the phone, tone stays', () async {
    store = JournalStore(
      journal: journal,
      defaults: const AlertDefaults(
        sound: true,
        vibration: true,
        tone: 'content://t/1',
        toneName: 'Bell',
      ),
      chats: {'old': const ChatAlert(sound: AlertChoice.off)},
    );
    remote.loadResult = const Ok(
      RemoteAlerts(
        sound: false,
        vibration: false,
        chats: {'new': ChatAlert(sound: AlertChoice.on)},
      ),
    );
    c = make();
    final p = await prefs();
    expect(p.defaults.sound, isFalse);
    expect(p.defaults.vibration, isFalse);
    expect(p.defaults.tone, 'content://t/1');
    expect(p.chats, {'new': const ChatAlert(sound: AlertChoice.on)});
    expect(store.defaults.sound, isFalse);
    expect(store.defaults.vibration, isFalse);
    expect(store.chats, {'new': const ChatAlert(sound: AlertChoice.on)});
    expect(remote.defaultsSaved, isEmpty);
  });

  test('start-up: an empty account gets the phone values once', () async {
    store = JournalStore(
      journal: journal,
      defaults: const AlertDefaults(sound: false, vibration: true),
      chats: {'c1': const ChatAlert(sound: AlertChoice.on)},
    );
    remote.loadResult = const Ok(RemoteAlerts(chats: {}));
    c = make();
    final p = await prefs();
    expect(p.defaults.sound, isFalse);
    expect(p.defaults.vibration, isTrue);
    expect(p.chat('c1'), const ChatAlert(sound: AlertChoice.on));
    expect(remote.defaultsSaved, [(false, true)]);
    expect(remote.chatsSaved, [('c1', const ChatAlert(sound: AlertChoice.on))]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(remote.defaultsSaved.length, 1);
    expect(remote.loads, 1);
  });

  test('start-up: the account cannot be read, the phone values stay', () async {
    store = JournalStore(
      journal: journal,
      defaults: const AlertDefaults(sound: false),
      chats: {'c1': const ChatAlert(vibration: AlertChoice.off)},
    );
    remote.loadResult = const Err(NetworkFailure('offline'));
    c = make();
    final p = await prefs();
    expect(p.defaults.sound, isFalse);
    expect(p.chat('c1'), const ChatAlert(vibration: AlertChoice.off));
    expect(remote.defaultsSaved, isEmpty);
    expect(remote.chatsSaved, isEmpty);
    expect(store.defaults, const AlertDefaults(sound: false));
    expect(store.chats.length, 1);
  });

  // BLOCK 3
  test(
    'account switch: the new account\'s values are loaded and mirrored',
    () async {
      remote.loadResult = const Ok(
        RemoteAlerts(sound: false, vibration: true, chats: {}),
      );
      c = make();
      var p = await prefs();
      expect(p.defaults.sound, isFalse);
      remote.loadResult = const Ok(
        RemoteAlerts(
          sound: true,
          vibration: false,
          chats: {'x': ChatAlert(vibration: AlertChoice.off)},
        ),
      );
      (c.read(currentUserIdProvider.notifier) as Me).set('u2');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      p = await prefs();
      expect(p.defaults.sound, isTrue);
      expect(p.defaults.vibration, isFalse);
      expect(p.chats, {'x': const ChatAlert(vibration: AlertChoice.off)});
      expect(store.defaults.sound, isTrue);
      expect(store.defaults.vibration, isFalse);
      expect(store.chats, {'x': const ChatAlert(vibration: AlertChoice.off)});
      expect(remote.loads, 2);
    },
  );

  test('no account connection: the phone alone works', () async {
    c = make(withRemote: false);
    await prefs();
    journal.events.clear();
    final r1 = await c
        .read(alertPrefsProvider.notifier)
        .setDefaults(const AlertDefaults(sound: false));
    final r2 = await c
        .read(alertPrefsProvider.notifier)
        .setChat('c1', const ChatAlert(sound: AlertChoice.on));
    expect(r1, isA<Ok<void>>());
    expect(r2, isA<Ok<void>>());
    expect(store.defaults.sound, isFalse);
    expect(store.chats, {'c1': const ChatAlert(sound: AlertChoice.on)});
    expect(journal.events.any((e) => e.startsWith('remote.')), isFalse);
    expect(remote.loads, 0);
  });

  test('back to Default saves the Default choice to the account and removes it on the phone', () async {
    store = JournalStore(
      journal: journal,
      chats: {'c1': const ChatAlert(sound: AlertChoice.off)},
    );
    remote.loadResult = const Ok(
      RemoteAlerts(
        sound: true,
        vibration: true,
        chats: {'c1': ChatAlert(sound: AlertChoice.off)},
      ),
    );
    c = make();
    await prefs();
    final r = await c
        .read(alertPrefsProvider.notifier)
        .setChat('c1', const ChatAlert());
    expect(r, isA<Ok<void>>());
    expect(remote.chatsSaved.last, ('c1', const ChatAlert()));
    expect(store.chats, isEmpty);
    expect((await prefs()).chats, isEmpty);
  });
}
