// The location bubble in a real MessageScreen and the chat-list preview,
// written from the contract: map preview, name, address, delivery ticks,
// reactions, menu actions, and preview line in English and Turkish.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:sis/features/chat/domain/geo.dart';
import 'package:sis/features/chat/domain/delivery.dart';

import '../../support/chat_launcher.dart';
import '../../support/reaction_fakes.dart';
import '../../support/location_fakes.dart';
import '../../support/fakes.dart';
import 'conversation_list_live_test.dart' show scope;

Finder k(String key) => find.byKey(ValueKey(key));

Future<void> openShare(WidgetTester t) async {
  await t.tap(k('composer-attach'));
  await t.pumpAndSettle();
  await t.tap(k('attach-location'));
  await t.pumpAndSettle();
}

Message locMsg({String id = 'm1', String from = 'u2', bool sending = false}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: 'Moda Pier\nKadikoy, Istanbul',
      createdAt: DateTime.now(),
      location: SharedLocation(
        lat: 40.98765,
        lng: 29.02345,
        name: 'Moda Pier',
        address: 'Kadikoy, Istanbul',
      ),
      sending: sending,
    );

Iterable<Delivery> ticks(WidgetTester t, String id) => t
    .widgetList<DeliveryTick>(
      find.descendant(
        of: k('location-$id'),
        matching: find.byType(DeliveryTick),
      ),
    )
    .map((d) => d.delivery);

Future<void> list(WidgetTester t, String lastMessage, {Locale? locale}) async {
  final chat = ChatFake()
    ..conversationsResult = Ok([
      Conversation(
        id: 'c1',
        other: bob,
        lastMessage: lastMessage,
        lastMessageAt: DateTime.now().toUtc(),
        lastSenderId: bob.userId,
      ),
    ]);
  final c = scope(chat);
  addTearDown(c.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const ConversationList(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  group('Location', () {
    testWidgets('the share page opens without asking for permission', (
      WidgetTester t,
    ) async {
      final device = FakeDeviceLocation();
      await openChat(t, overrides: locationOverrides(device: device));
      await openShare(t);
      expect(k('location-share-current'), findsOneWidget);
      expect(k('location-pick'), findsOneWidget);
      expect(device.currentCalls, 0);
    });

    testWidgets('denied: says so and sends nothing', (WidgetTester t) async {
      final device = FakeDeviceLocation();
      device.answer = const Err(LocationDeniedFailure());
      final share = FakeLocationShare();
      await openChat(
        t,
        overrides: locationOverrides(device: device, share: share),
      );
      await openShare(t);
      await t.tap(k('location-share-current'));
      await t.pumpAndSettle();
      expect(
        find.text(
          'Location is turned off for SIS. Turn it on in the phone settings, or pick a place on the map.',
        ),
        findsWidgets,
      );
      expect(share.calls, isEmpty);
      await t.pump(const Duration(seconds: 10));
      await t.pumpAndSettle();
    });

    testWidgets('denied forever: says so and sends nothing', (
      WidgetTester t,
    ) async {
      final device = FakeDeviceLocation();
      device.answer = const Err(LocationDeniedFailure(forever: true));
      final share = FakeLocationShare();
      await openChat(
        t,
        overrides: locationOverrides(device: device, share: share),
      );
      await openShare(t);
      await t.tap(k('location-share-current'));
      await t.pumpAndSettle();
      expect(
        find.text(
          'Location is turned off for SIS. Turn it on in the phone settings, or pick a place on the map.',
        ),
        findsWidgets,
      );
      expect(share.calls, isEmpty);
      await t.pump(const Duration(seconds: 10));
      await t.pumpAndSettle();
    });

    testWidgets('unavailable: says so', (WidgetTester t) async {
      final device = FakeDeviceLocation();
      device.answer = const Err(LocationUnavailableFailure());
      final share = FakeLocationShare();
      await openChat(
        t,
        overrides: locationOverrides(device: device, share: share),
      );
      await openShare(t);
      await t.tap(k('location-share-current'));
      await t.pumpAndSettle();
      expect(
        find.text('Could not find your position. Check that location is on.'),
        findsWidgets,
      );
      expect(share.calls, isEmpty);
      await t.pump(const Duration(seconds: 10));
      await t.pumpAndSettle();
    });

    testWidgets('share current sends my position to this chat', (
      WidgetTester t,
    ) async {
      final device = FakeDeviceLocation();
      final share = FakeLocationShare();
      await openChat(
        t,
        overrides: locationOverrides(device: device, share: share),
      );
      await openShare(t);
      await t.tap(k('location-share-current'));
      await t.pumpAndSettle();
      expect(share.calls.single.$1, 'c1');
      expect(share.calls.single.$3.lat, 41.0);
      expect(share.calls.single.$3.lng, 29.0);
      expect(k('location-${share.calls.single.$2}'), findsOneWidget);
      expect(k('location-share-current'), findsNothing);
    });

    testWidgets('offline: the card stays with the clock', (
      WidgetTester t,
    ) async {
      final share = FakeLocationShare();
      share.answer = const Err(NetworkFailure('offline', retryable: true));
      await openChat(t, overrides: locationOverrides(share: share));
      await openShare(t);
      await t.tap(k('location-share-current'));
      await t.pumpAndSettle();
      final id = share.calls.first.$2;
      expect(k('location-$id'), findsOneWidget);
      expect(ticks(t, id), [Delivery.pending]);
      // Back online: the queued card goes out and loses the clock.
      share.answer = const Ok(null);
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      expect(share.calls.length, greaterThan(1));
      expect(share.calls.map((c) => c.$2).toSet(), {id});
      expect(ticks(t, id).single, isNot(Delivery.pending));
    });

    testWidgets('no search pill when search cannot work', (t) async {
      final search = FakePlaceSearch(canSearch: false);
      await openChat(t, overrides: locationOverrides(search: search));
      await openShare(t);
      expect(k('location-search-pill'), findsNothing);
    });

    testWidgets('the search pill shows when search works', (t) async {
      final search = FakePlaceSearch(canSearch: true);
      await openChat(t, overrides: locationOverrides(search: search));
      await openShare(t);
      expect(k('location-search-pill'), findsOneWidget);
    });

    testWidgets('pick a place on the map and send it', (WidgetTester t) async {
      final map = FakeMap();
      final search = FakePlaceSearch();
      final share = FakeLocationShare();
      await openChat(
        t,
        overrides: locationOverrides(map: map, search: search, share: share),
      );
      await openShare(t);
      await t.tap(k('location-pick'));
      await t.pumpAndSettle();
      map.drag(const GeoPoint(40.99, 29.03));
      await t.pumpAndSettle();
      expect(find.text('Pin street 1'), findsWidgets);
      await t.tap(k('location-send'));
      await t.pumpAndSettle();
      final call = share.calls.single;
      expect(call.$3.lat, 40.99);
      expect(call.$3.lng, 29.03);
      expect(call.$3.name, 'Pin street 1');
      expect(call.$3.address, 'Kadikoy, Istanbul');
    });

    testWidgets('a searched place is sent', (WidgetTester t) async {
      final search = FakePlaceSearch();
      search.results['moda'] = [
        PlaceSuggestion(
          id: 'p1',
          name: 'Moda Pier',
          address: 'Kadikoy, Istanbul',
        ),
      ];
      search.places['p1'] = Place(
        point: GeoPoint(40.98765, 29.02345),
        name: 'Moda Pier',
        address: 'Kadikoy, Istanbul',
      );
      final share = FakeLocationShare();
      await openChat(
        t,
        overrides: locationOverrides(search: search, share: share),
      );
      await openShare(t);
      // The pill opens the search field on the pick page.
      await t.tap(k('location-search-pill'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'moda');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(k('location-suggestion-p1'));
      await t.pumpAndSettle();
      await t.tap(k('location-send'));
      await t.pumpAndSettle();
      final call = share.calls.single;
      expect(call.$3.name, 'Moda Pier');
      expect(call.$3.lat, 40.98765);
    });

    testWidgets('the card shows the map, name and address', (
      WidgetTester t,
    ) async {
      await openChat(t, messages: [locMsg()], overrides: locationOverrides());
      await settle(t);
      final card = k('location-m1');
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(ValueKey('test-preview-40.98765,29.02345')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Moda Pier')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Kadikoy, Istanbul')),
        findsOneWidget,
      );
    });

    testWidgets('my pending -> ticks [Delivery.pending]', (
      WidgetTester t,
    ) async {
      await openChat(
        t,
        messages: [locMsg(from: 'u1', sending: true)],
        overrides: locationOverrides(),
      );
      await settle(t);
      expect(ticks(t, 'm1'), [Delivery.pending]);
    });

    testWidgets('my sent (from u1) -> one tick, not pending', (
      WidgetTester t,
    ) async {
      await openChat(
        t,
        messages: [locMsg(from: 'u1')],
        overrides: locationOverrides(),
      );
      await settle(t);
      expect(ticks(t, 'm1'), hasLength(1));
      expect(ticks(t, 'm1').single, isNot(Delivery.pending));
    });

    testWidgets('from u2 -> no ticks', (WidgetTester t) async {
      await openChat(
        t,
        messages: [locMsg(from: 'u2')],
        overrides: locationOverrides(),
      );
      await settle(t);
      expect(ticks(t, 'm1'), isEmpty);
    });

    testWidgets('reactions under the card', (WidgetTester t) async {
      final fake = ReactionFake()
        ..seed('c1', [Reaction(messageId: 'm1', userId: 'u2', emoji: '👍')]);
      await openChat(
        t,
        messages: [locMsg(from: 'u2')],
        reactions: fake,
        overrides: locationOverrides(),
      );
      expect(k('reactions-m1'), findsOneWidget);
      expect(k('reaction-chip-m1-👍'), findsOneWidget);
    });

    testWidgets('tapping the card asks first; cancel opens nothing', (
      WidgetTester t,
    ) async {
      final opener = FakeMapsOpener();
      await openChat(
        t,
        messages: [locMsg()],
        overrides: locationOverrides(opener: opener),
      );
      await t.tap(k('location-m1'));
      await t.pumpAndSettle();
      expect(k('open-maps-card'), findsOneWidget);
      expect(opener.opened, isEmpty);
      await t.tap(k('open-maps-cancel'));
      await t.pumpAndSettle();
      expect(opener.opened, isEmpty);
      expect(k('open-maps-card'), findsNothing);
    });

    testWidgets('confirm opens the maps app at the place', (
      WidgetTester t,
    ) async {
      final opener = FakeMapsOpener();
      await openChat(
        t,
        messages: [locMsg()],
        overrides: locationOverrides(opener: opener),
      );
      await t.tap(k('location-m1'));
      await t.pumpAndSettle();
      await t.tap(k('open-maps-confirm'));
      await t.pumpAndSettle();
      expect(opener.opened.single.$1, const GeoPoint(40.98765, 29.02345));
    });

    testWidgets('no maps app: says so', (WidgetTester t) async {
      final opener = FakeMapsOpener();
      opener.answer = false;
      await openChat(
        t,
        messages: [locMsg()],
        overrides: locationOverrides(opener: opener),
      );
      await t.tap(k('location-m1'));
      await t.pumpAndSettle();
      await t.tap(k('open-maps-confirm'));
      await t.pumpAndSettle();
      expect(find.text('No maps app could open this place.'), findsWidgets);
      await t.pump(const Duration(seconds: 10));
      await t.pumpAndSettle();
    });

    testWidgets('the menu of my sent location has no forward and no edit', (
      WidgetTester t,
    ) async {
      await openChat(
        t,
        messages: [locMsg(from: 'u1')],
        overrides: locationOverrides(),
      );
      await t.longPress(bubble('m1'));
      await t.pumpAndSettle();
      expect(k('message-menu'), findsOneWidget);
      expect(k('menu-reply'), findsOneWidget);
      expect(k('menu-forward'), findsNothing);
      expect(k('menu-edit'), findsNothing);
    });

    testWidgets('the chat list shows a location in English', (
      WidgetTester t,
    ) async {
      await list(t, locationPreviewText);
      expect(
        find.descendant(
          of: k('preview-c1'),
          matching: find.text('📍 Location'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('the chat list shows a location in Turkish', (
      WidgetTester t,
    ) async {
      await list(t, locationPreviewText, locale: const Locale('tr'));
      expect(
        find.descendant(
          of: k('preview-c1'),
          matching: find.text('📍 Konum'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });
  });
}
