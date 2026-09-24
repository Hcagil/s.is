// The one thing the contract pins down about where MuteTile is placed: the
// person page must mute the PERSON (kind person, target = their user id),
// never the conversation, and the group page must mute the CONVERSATION
// (kind conversation, target = its id), never a person. Everything else
// about these pages — tabs, status, media, links — belongs to
// test/features/chat/profile_pages_test.dart; this file exists only to pin
// the notifications wiring on top of it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

Finder byKey(String key) => find.byKey(ValueKey(key));

Widget host(Widget child, NotificationSettingsFake notif) => ProviderScope(
  overrides: [
    chatRepositoryProvider.overrideWithValue(ChatFake()),
    presenceRepositoryProvider.overrideWithValue(PresenceFake()),
    notificationSettingsRepositoryProvider.overrideWithValue(notif),
  ],
  child: MaterialApp(home: child),
);

Future<void> muteViaTile(WidgetTester t) async {
  await t.tap(byKey('mute-tile'));
  await t.pumpAndSettle();
  await t.tap(byKey('mute-always'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the person page mutes the person, not the conversation', (
    t,
  ) async {
    final fake = NotificationSettingsFake();
    await t.pumpWidget(
      host(
        const PersonScreen(
          userId: 'ub',
          fallbackName: 'Bob',
          showMessage: false,
        ),
        fake,
      ),
    );
    await t.pumpAndSettle();

    await muteViaTile(t);

    final (kind, target, until) = fake.muteCalls.single;
    expect(
      kind,
      MuteKind.person,
      reason: 'the person page must mute the person',
    );
    expect(target, 'ub');
    expect(until, isNull, reason: 'Always was picked');
  });

  testWidgets('the group page mutes the conversation, not a person', (t) async {
    final fake = NotificationSettingsFake();
    await t.pumpWidget(
      host(const GroupScreen(conversationId: 'g1', title: 'Club'), fake),
    );
    await t.pumpAndSettle();

    await muteViaTile(t);

    final (kind, target, until) = fake.muteCalls.single;
    expect(
      kind,
      MuteKind.conversation,
      reason: 'the group page must mute the conversation',
    );
    expect(target, 'g1');
    expect(until, isNull, reason: 'Always was picked');
  });
}
