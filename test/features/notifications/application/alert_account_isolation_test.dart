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

class ThrowingStore extends JournalStore {
  ThrowingStore({required super.journal, super.defaults, super.chats});

  bool failWrites = false;

  @override
  Future<void> saveDefaults(AlertDefaults d) async {
    if (failWrites) throw StateError('disk full');
    return super.saveDefaults(d);
  }

  @override
  Future<void> saveChat(String conversationId, ChatAlert c) async {
    if (failWrites) throw StateError('disk full');
    return super.saveChat(conversationId, c);
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

ProviderContainer make(AlertStore st, AlertRemote r, String user) {
  final container = ProviderContainer(
    overrides: [
      alertStoreProvider.overrideWithValue(st),
      tonePickerProvider.overrideWithValue(NoPicker()),
      currentUserIdProvider.overrideWith(() => Me(user)),
      alertRemoteProvider.overrideWithValue(r),
    ],
  );
  container.listen(alertPrefsProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

Future<AlertPrefs> prefs(ProviderContainer c) =>
    c.read(alertPrefsProvider.future);

void main() {
  test(
    'D1: account B signing in on the same phone does not get account A choices',
    () async {
      final journal = Journal();
      final phone = JournalStore(journal: journal);
      final remoteA = FakeRemote(journal);
      final remoteB = FakeRemote(journal);
      remoteA.loadResult = const Ok(RemoteAlerts(chats: {}));
      remoteB.loadResult = const Ok(RemoteAlerts(chats: {}));

      // Step 1
      final containerA = make(phone, remoteA, 'a');
      await prefs(containerA);
      await containerA
          .read(alertPrefsProvider.notifier)
          .setDefaults(const AlertDefaults(sound: false, vibration: false));
      await containerA
          .read(alertPrefsProvider.notifier)
          .setChat('c1', const ChatAlert(sound: AlertChoice.off));
      containerA.dispose();

      // Step 2
      final containerB = make(phone, remoteB, 'b');
      final pb = await prefs(containerB);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pb.defaults.sound, isTrue);
      expect(pb.defaults.vibration, isTrue);
      expect(pb.chat('c1'), const ChatAlert());
      expect(remoteB.defaultsSaved, isEmpty);
      expect(remoteB.chatsSaved, isEmpty);
      containerB.dispose();

      // Step 3
      final remoteA2 = FakeRemote(journal);
      remoteA2.loadResult = const Ok(
        RemoteAlerts(
          sound: false,
          vibration: false,
          chats: {'c1': ChatAlert(sound: AlertChoice.off)},
        ),
      );
      final containerA2 = make(phone, remoteA2, 'a');
      final pa = await prefs(containerA2);
      expect(pa.defaults.sound, isFalse);
      expect(pa.chat('c1'), const ChatAlert(sound: AlertChoice.off));
      containerA2.dispose();
    },
  );

  test('D2: a phone write that throws after the account write succeeded returns Err, no exception escapes', () async {
    final journal = Journal();
    final store = ThrowingStore(journal: journal)..failWrites = true;
    final remote = FakeRemote(journal);
    remote.loadResult = const Ok(RemoteAlerts(chats: {}));
    final c = make(store, remote, 'a');
    await prefs(c);

    final r1 = await c
        .read(alertPrefsProvider.notifier)
        .setDefaults(const AlertDefaults(sound: false));
    expect(r1, isA<Err<void>>());

    final r2 = await c
        .read(alertPrefsProvider.notifier)
        .setChat('c1', const ChatAlert(sound: AlertChoice.off));
    expect(r2, isA<Err<void>>());
  });
}
