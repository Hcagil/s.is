// test/features/chat/new_chat_search_race_repro_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/contacts_repository.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const dee = Member(userId: 'ud', displayName: 'Dee Kurt', tag: 'dee');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');

const withBob = Conversation(id: 'c1', other: bob, lastMessage: 'hi');

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

/// Fake repository that records tags and allows manual completion of look‑ups.
class RaceContacts implements ContactsRepository {
  RaceContacts();

  final tags = <String>[];
  final pending = <String, Completer<Member?>>{};

  @override
  Future<Result<Set<String>>> ids() async => Ok({});

  @override
  Future<Result<void>> add(String userId) async => Ok(null);

  @override
  Future<Result<void>> remove(String userId) async => Ok(null);

  @override
  Future<Result<Member?>> findByTag(String tag) async {
    tags.add(tag);
    final completer = Completer<Member?>();
    pending[tag] = completer;
    return Ok(await completer.future);
  }

  @override
  Future<Result<List<ContactMatch>>> findByContacts(
    List<String> hashes,
  ) async => Ok(<ContactMatch>[]);
}

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await steps(t);
}

Future<void> openNewChat(WidgetTester t) => tapKey(t, 'new-chat');

Future<void> pumpApp(WidgetTester t, RaceContacts race) async {
  final chat = ChatFake(latency: const Duration(milliseconds: 2))
    ..conversationsResult = const Ok([withBob]);

  await t.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(
          FakeAuth(session: true, member: me),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(chat),
        contactsRepositoryProvider.overrideWithValue(race),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(
          ProfileFake(
            profile: const OwnProfile(
              userId: 'u1',
              displayName: 'Maya Kaya',
              tag: 'maya',
              onboardingDone: true,
            ),
          ),
        ),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      ],
      child: const SisApp(),
    ),
  );
  await steps(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

void main() {
  testWidgets('a slow first search never overwrites the newer one', (t) async {
    final race = RaceContacts();
    await pumpApp(t, race);
    await openNewChat(t);

    // First search for 'bobby'
    await t.enterText(byKey('find-by-tag-field'), 'bobby');
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.search);
    await steps(t, 2);
    expect(race.pending, contains('bobby'), reason: 'first search pending');

    // Second search for 'dee' while first is still pending
    await t.enterText(byKey('find-by-tag-field'), 'dee');
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.search);
    await steps(t, 2);
    expect(race.pending, contains('dee'), reason: 'second search pending');

    // Resolve second search first
    race.pending['dee']!.complete(dee);
    await steps(t);
    // Then resolve first search
    race.pending['bobby']!.complete(bob);
    await steps(t);

    // Verify only dee is shown
    expect(
      byKey('find-by-tag-result-${dee.userId}'),
      findsOneWidget,
      reason: 'dee result present',
    );
    expect(
      byKey('find-by-tag-result-${bob.userId}'),
      findsNothing,
      reason: 'bob result absent',
    );

    // Verify field text remains 'dee'
    final field = t.widget<TextField>(byKey('find-by-tag-field'));
    expect(field.controller!.text, 'dee', reason: 'field text unchanged');

    // Tap dee chat button
    await tapKey(t, 'find-by-tag-chat-${dee.userId}');
    // Verify chat opened with Dee only
    expect(find.text('Dee Kurt'), findsWidgets, reason: 'chat with Dee opened');
  });
}
