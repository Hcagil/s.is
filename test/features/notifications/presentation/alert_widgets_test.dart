// AlertDefaultsSection and ChatAlertTiles, from the contract: keys, what
// each control saves, the Android-only gating of tone and vibration, the
// tone tile disabled while sound is off, nothing drawn until the settings
// have loaded, and where the pages mount them.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/app/controls.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/alert_controller.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/alert_settings.dart';
import 'package:sis/features/notifications/presentation/alert_widgets.dart';
import 'package:sis/features/notifications/presentation/notification_pages.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../../support/fakes.dart';
import '../../../support/l10n.dart';

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

const bob = Member(userId: 'ub', displayName: 'Bob Stone');

/// A widget test on [platform]; the override is always undone, as the
/// binding requires, even when the body fails.
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

void main() {
  late MemoryStore store;
  late CountingPicker picker;

  setUp(() {
    store = MemoryStore();
    picker = CountingPicker();
  });

  List<Override> ports() => [
    alertStoreProvider.overrideWithValue(store),
    tonePickerProvider.overrideWithValue(picker),
  ];

  Future<void> mount(WidgetTester t, Widget child) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: ports(),
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

  Future<void> choose(WidgetTester t, String dropdownKey, String item) async {
    await t.tap(byKey(dropdownKey));
    await t.pumpAndSettle();
    await t.tap(find.text(item).last);
    await t.pumpAndSettle();
  }

  group('AlertDefaultsSection', () {
    onPlatform(
      TargetPlatform.android,
      'draws nothing until the settings load',
      (t) async {
        store.hold = Completer<void>();
        await t.pumpWidget(
          ProviderScope(
            overrides: ports(),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: AlertDefaultsSection()),
            ),
          ),
        );
        await t.pump();
        expect(byKey('alert-sound'), findsNothing);
        expect(byKey('alert-tone'), findsNothing);
        expect(byKey('alert-vibration'), findsNothing);

        store.hold!.complete();
        await t.pumpAndSettle();
        expect(byKey('alert-sound'), findsOneWidget);
      },
    );

    onPlatform(
      TargetPlatform.android,
      'Android: sound, tone and vibration, reflecting the saved '
      'values',
      (t) async {
        store.defaults = const AlertDefaults(vibration: false);
        await mount(t, const AlertDefaultsSection());

        expect(byKey('alert-sound'), findsOneWidget);
        expect(byKey('alert-tone'), findsOneWidget);
        expect(byKey('alert-vibration'), findsOneWidget);
        expect(switchOn(t, 'alert-sound'), isTrue);
        expect(switchOn(t, 'alert-vibration'), isFalse);
        expect(
          find.descendant(
            of: byKey('alert-tone'),
            matching: find.text('System default'),
          ),
          findsOneWidget,
        );
      },
    );

    onPlatform(
      TargetPlatform.android,
      'the tone subtitle is the saved tone\'s name',
      (t) async {
        store.defaults = const AlertDefaults(
          tone: 'content://t/1',
          toneName: 'Bell',
        );
        await mount(t, const AlertDefaultsSection());

        expect(
          find.descendant(of: byKey('alert-tone'), matching: find.text('Bell')),
          findsOneWidget,
        );
        expect(find.text('System default'), findsNothing);
      },
    );

    onPlatform(
      TargetPlatform.iOS,
      'iOS: sound only; tone and vibration are Android-only',
      (t) async {
        await mount(t, const AlertDefaultsSection());

        expect(byKey('alert-sound'), findsOneWidget);
        expect(byKey('alert-tone'), findsNothing);
        expect(byKey('alert-vibration'), findsNothing);
      },
    );

    onPlatform(
      TargetPlatform.android,
      'turning sound off saves it and disables the tone',
      (t) async {
        await mount(t, const AlertDefaultsSection());

        await t.tap(byKey('alert-sound'));
        await t.pumpAndSettle();

        expect(store.defaults.sound, isFalse);
        expect(store.defaults.vibration, isTrue);
        expect(switchOn(t, 'alert-sound'), isFalse);

        await t.tap(byKey('alert-tone'), warnIfMissed: false);
        await t.pumpAndSettle();
        expect(picker.asked, 0, reason: 'tone must be disabled with sound off');
      },
    );

    onPlatform(
      TargetPlatform.android,
      'with sound on, the tone opens the picker and shows the '
      'picked name',
      (t) async {
        picker.next = const PickedTone(tone: 'content://t/9', name: 'Chime');
        await mount(t, const AlertDefaultsSection());

        await t.tap(byKey('alert-tone'));
        await t.pumpAndSettle();

        expect(picker.asked, 1);
        expect(store.defaults.tone, 'content://t/9');
        expect(
          find.descendant(
            of: byKey('alert-tone'),
            matching: find.text('Chime'),
          ),
          findsOneWidget,
        );
      },
    );

    onPlatform(TargetPlatform.android, 'vibration off is saved', (t) async {
      await mount(t, const AlertDefaultsSection());

      await t.tap(byKey('alert-vibration'));
      await t.pumpAndSettle();

      expect(store.defaults.vibration, isFalse);
      expect(store.defaults.sound, isTrue);
      expect(switchOn(t, 'alert-vibration'), isFalse);
    });
  });

  group('ChatAlertTiles', () {
    onPlatform(
      TargetPlatform.android,
      'draws nothing until the settings load',
      (t) async {
        store.hold = Completer<void>();
        await t.pumpWidget(
          ProviderScope(
            overrides: ports(),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: ChatAlertTiles(conversationId: 'g1')),
            ),
          ),
        );
        await t.pump();
        expect(byKey('chat-alert-sound'), findsNothing);
        expect(byKey('chat-alert-vibration'), findsNothing);

        store.hold!.complete();
        await t.pumpAndSettle();
        expect(byKey('chat-alert-sound'), findsOneWidget);
      },
    );

    onPlatform(
      TargetPlatform.android,
      'Android: sound and vibration, each Default/On/Off',
      (t) async {
        await mount(t, const ChatAlertTiles(conversationId: 'g1'));

        expect(byKey('chat-alert-sound'), findsOneWidget);
        expect(byKey('chat-alert-vibration'), findsOneWidget);
        expect(byKey('chat-alert-sound-choice'), findsOneWidget);
        expect(byKey('chat-alert-vibration-choice'), findsOneWidget);

        await t.tap(byKey('chat-alert-sound-choice'));
        await t.pumpAndSettle();
        for (final item in ['Default', 'On', 'Off']) {
          expect(find.text(item), findsWidgets, reason: item);
        }
      },
    );

    onPlatform(TargetPlatform.iOS, 'iOS: sound only', (t) async {
      await mount(t, const ChatAlertTiles(conversationId: 'g1'));

      expect(byKey('chat-alert-sound'), findsOneWidget);
      expect(byKey('chat-alert-sound-choice'), findsOneWidget);
      expect(byKey('chat-alert-vibration'), findsNothing);
      expect(byKey('chat-alert-vibration-choice'), findsNothing);
    });

    onPlatform(
      TargetPlatform.android,
      'picking Off saves this chat\'s override; Default removes it',
      (t) async {
        await mount(t, const ChatAlertTiles(conversationId: 'g1'));

        await choose(t, 'chat-alert-sound-choice', 'Off');
        expect(store.chats, {'g1': const ChatAlert(sound: AlertChoice.off)});

        await choose(t, 'chat-alert-vibration-choice', 'On');
        expect(store.chats, {
          'g1': const ChatAlert(
            sound: AlertChoice.off,
            vibration: AlertChoice.on,
          ),
        });

        await choose(t, 'chat-alert-sound-choice', 'Default');
        await choose(t, 'chat-alert-vibration-choice', 'Default');
        expect(store.chats, isEmpty);
        expect(store.saved.last, ('g1', const ChatAlert()));
      },
    );

    onPlatform(TargetPlatform.android, 'shows the saved choice of THIS chat', (
      t,
    ) async {
      store.chats['g1'] = const ChatAlert(sound: AlertChoice.off);
      store.chats['g2'] = const ChatAlert(sound: AlertChoice.on);
      await mount(t, const ChatAlertTiles(conversationId: 'g1'));

      final d = t.widget<DropdownButton<AlertChoice>>(
        find.descendant(
          of: byKey('chat-alert-sound-choice'),
          matching: find.byType(DropdownButton<AlertChoice>),
          matchRoot: true,
        ),
      );
      expect(d.value, AlertChoice.off);
    });
  });

  group('where the pages mount them', () {
    List<Override> pageOverrides(ChatFake chat) => [
      ...ports(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      notificationSettingsRepositoryProvider.overrideWithValue(
        NotificationSettingsFake(),
      ),
    ];

    onPlatform(
      TargetPlatform.android,
      'Settings > Notifications: the defaults sit above Muted',
      (t) async {
        await t.pumpWidget(
          ProviderScope(
            overrides: pageOverrides(ChatFake()),
            child: localizedApp(home: NotificationsScreen()),
          ),
        );
        await t.pumpAndSettle();

        expect(byKey('alert-sound'), findsOneWidget);
        await t.scrollUntilVisible(find.text('Muted'), 200);
        expect(
          t.getTopLeft(byKey('alert-vibration')).dy,
          lessThan(t.getTopLeft(find.text('Muted')).dy),
        );
      },
    );

    onPlatform(
      TargetPlatform.android,
      'the group page offers this group\'s alert choice',
      (t) async {
        await t.pumpWidget(
          ProviderScope(
            overrides: pageOverrides(ChatFake()),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: GroupScreen(conversationId: 'g1', title: 'Club'),
            ),
          ),
        );
        await t.pumpAndSettle();

        await choose(t, 'chat-alert-sound-choice', 'Off');
        expect(store.chats.keys, ['g1']);
      },
    );

    onPlatform(
      TargetPlatform.android,
      'the person page offers it for the 1:1 with them',
      (t) async {
        final chat = ChatFake()
          ..conversationsResult = const Ok([
            Conversation(id: 'c-bob', other: bob, lastMessage: 'hi'),
          ]);
        await t.pumpWidget(
          ProviderScope(
            overrides: pageOverrides(chat),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PersonScreen(
                userId: 'ub',
                fallbackName: 'Bob',
                showMessage: false,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();

        await choose(t, 'chat-alert-sound-choice', 'Off');
        expect(store.chats, {'c-bob': const ChatAlert(sound: AlertChoice.off)});
      },
    );

    onPlatform(
      TargetPlatform.android,
      'no 1:1 with them yet: no per-chat choice',
      (t) async {
        await t.pumpWidget(
          ProviderScope(
            overrides: pageOverrides(ChatFake()),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PersonScreen(
                userId: 'ub',
                fallbackName: 'Bob',
                showMessage: false,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();

        expect(byKey('mute-tile'), findsOneWidget, reason: 'the page drew');
        expect(byKey('chat-alert-sound'), findsNothing);
      },
    );
  });
}
