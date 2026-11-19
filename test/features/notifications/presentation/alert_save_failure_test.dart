import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/notifications/application/alert_controller.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';
import 'package:sis/features/notifications/presentation/alert_widgets.dart';

import '../../../support/sis_ui.dart';

Finder byKey(String key) => find.byKey(ValueKey(key));

/// Settings kept in memory; a load can be held to show the loading state.
class MemoryStore implements AlertStore {
  AlertDefaults defaults = const AlertDefaults();
  final chats = <String, ChatAlert>{};
  final saved = <Object>[];
  Completer<void>? hold;

  @override
  Future<AlertDefaults> loadDefaults() async {
    await hold?.future;
    return defaults;
  }

  @override
  Future<Map<String, ChatAlert>> loadChats() async {
    await hold?.future;
    return Map.of(chats);
  }

  @override
  Future<void> saveDefaults(AlertDefaults d) async {
    saved.add(d);
    defaults = d;
  }

  @override
  Future<void> saveChat(String id, ChatAlert c) async {
    saved.add((id, c));
    c.isDefault ? chats.remove(id) : chats[id] = c;
  }
}

class CountingPicker implements TonePicker {
  PickedTone? next;
  int asked = 0;

  @override
  Future<PickedTone?> pick(String? currentTone) async {
    asked++;
    return next;
  }
}

class Me extends CurrentUserId {
  Me(this.id);
  final String? id;
  @override
  String? build() => id;
}

class FailingRemote implements AlertRemote {
  int chatSaves = 0;
  @override
  Future<Result<RemoteAlerts>> load() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return const Ok(
      RemoteAlerts(
        sound: true,
        vibration: true,
        chats: {'g1': ChatAlert(sound: AlertChoice.off)},
      ),
    );
  }

  @override
  Future<Result<void>> saveDefaults({
    required bool sound,
    required bool vibration,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return const Err<void>(NetworkFailure('offline'));
  }

  @override
  Future<Result<void>> saveChat(String conversationId, ChatAlert c) async {
    chatSaves++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return const Err<void>(NetworkFailure('offline'));
  }
}

void onPlatform(
  TargetPlatform platform,
  String description,
  WidgetTesterCallback body,
) => testWidgets(description, (t) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body(t);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
});

Future<void> mount(
  WidgetTester t,
  Widget child,
  AlertStore store,
  TonePicker picker,
  AlertRemote remote,
) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        alertStoreProvider.overrideWithValue(store),
        tonePickerProvider.overrideWithValue(picker),
        currentUserIdProvider.overrideWith(() => Me('u1')),
        alertRemoteProvider.overrideWithValue(remote),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ListView(children: [child])),
      ),
    ),
  );
  await t.pumpAndSettle();
}

bool switchOn(WidgetTester t, String key) {
  return t.widget<SisSwitchTile>(byKey(key)).value;
}

Future<void> choose(WidgetTester t, String rowKey, String choice) async {
  await t.tap(byKey(rowKey));
  await t.pumpAndSettle();
  await t.tap(byKey('alert-choice-$choice'));
  await t.pumpAndSettle();
  await t.tap(byKey('alert-choice-save'));
  await t.pumpAndSettle();
}

void main() {
  late MemoryStore store;
  late CountingPicker picker;
  late FailingRemote remote;

  setUp(() {
    store = MemoryStore();
    picker = CountingPicker();
    remote = FailingRemote();
  });

  onPlatform(
    TargetPlatform.android,
    'a failed save shows the notice and keeps the old choice',
    (t) async {
      await mount(
        t,
        const ChatAlertTiles(conversationId: 'g1'),
        store,
        picker,
        remote,
      );
      await t.pumpAndSettle();

      expect(notice, findsNothing);

      await t.tap(byKey('chat-alert-sound'));
      await t.pumpAndSettle();

      expect(
        t
            .widget<SisChoiceCard<AlertChoice>>(byKey('alert-choice-off'))
            .groupValue,
        AlertChoice.off,
      );

      await t.tap(byKey('alert-choice-on'));
      await t.pumpAndSettle();

      await t.tap(byKey('alert-choice-save'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(notice, findsOneWidget);
      expect(remote.chatSaves, 1);
      expect(store.chats['g1']?.sound, AlertChoice.off);
      expect(store.chats['g1']?.sound, isNot(AlertChoice.on));

      await drainNotice(t);
      await t.pumpAndSettle();

      // reopen the row
      if (byKey('alert-choice-save').evaluate().isNotEmpty) {
        await t.tapAt(const Offset(10, 10));
        await t.pumpAndSettle();
      }

      await t.tap(byKey('chat-alert-sound'));
      await t.pumpAndSettle();

      expect(
        t
            .widget<SisChoiceCard<AlertChoice>>(byKey('alert-choice-off'))
            .groupValue,
        AlertChoice.off,
      );
    },
  );
}
