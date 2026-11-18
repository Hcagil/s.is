// AlertLegacyMigration against fakes of its two ports, written from the
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
  int saveFailuresLeft = 0;
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
    if (saveFailuresLeft > 0) {
      saveFailuresLeft--;
      return const Err<void>(NetworkFailure('offline'));
    }
    if (saveResult is Ok) {
      defaultsSaved.add((sound, vibration));
    }
    return saveResult;
  }

  @override
  Future<Result<void>> saveChat(String conversationId, ChatAlert c) async {
    await Future<void>.delayed(_latency);
    journal.events.add('remote.saveChat:$conversationId');
    if (saveFailuresLeft > 0) {
      saveFailuresLeft--;
      return const Err<void>(NetworkFailure('offline'));
    }
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
    remote.loadResult = const Ok(RemoteAlerts(chats: {}));
  });

  test('F1: an account row made before the update (sound/vibration null, never saved) must not overwrite the phone off choice',
      () async {
    store = JournalStore(
      journal: journal,
      defaults: const AlertDefaults(sound: false, vibration: false),
    );
    remote.loadResult = const Ok(RemoteAlerts(chats: {}));
    c = make();
    final p = await prefs();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(p.defaults.sound, isFalse);
    expect(p.defaults.vibration, isFalse);
    expect(store.defaults.sound, isFalse);
    expect(remote.defaultsSaved, [(false, false)]);
  });

  test('F2: a failed first copy to the account is retried on the next start and no choice is lost',
      () async {
    store = JournalStore(
      journal: journal,
      defaults: const AlertDefaults(sound: false, vibration: true),
      chats: {'c1': const ChatAlert(sound: AlertChoice.on)},
    );
    remote.loadResult = const Ok(RemoteAlerts(chats: {}));
    remote.saveFailuresLeft = 2; // both defaults and chat fail first start
    c = make();
    await prefs();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(remote.defaultsSaved, isEmpty);
    expect(remote.chatsSaved, isEmpty);

    // second start
    remote.saveFailuresLeft = 0;
    c = make(); // new container, same store and remote
    await prefs();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(remote.defaultsSaved, [(false, true)]);
    expect(remote.chatsSaved, [('c1', const ChatAlert(sound: AlertChoice.on))]);
    expect((await prefs()).defaults.sound, isFalse);
  });

  test('F3: an account that saved true/true keeps them over this phone off choice (cross-device)', () async {
    store = JournalStore(
      journal: journal,
      defaults: const AlertDefaults(sound: false, vibration: false),
    );
    remote.loadResult = const Ok(RemoteAlerts(sound: true, vibration: true, chats: {}));
    c = make();
    final p = await prefs();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(p.defaults.sound, isTrue);
    expect(p.defaults.vibration, isTrue);
    expect(store.defaults.sound, isTrue);
    expect(remote.defaultsSaved, isEmpty);
  });
}
