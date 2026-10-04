// openConversation, from the 0.30.13 contract: called from a list tile, it
// finishes its after-pop sequence -- markRead, then restore or close the open
// conversation only while it is still the same one, then reloadQuietly --
// even when the calling tile is gone by then (the list rebuilt it away while
// the chat was open), and with no ref-after-unmount error.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/auth/application/session_controller.dart';

import '../../support/chat_launcher.dart'
    show SignedInForTests, chatMessage, me, osBack;
import '../../support/fakes.dart';

/// A list row: its own ConsumerWidget, so its ref dies when it is removed.
class _Tile extends ConsumerWidget {
  const _Tile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton(
    key: const ValueKey('tile-c1'),
    onPressed: () => openConversation(context, ref, 'c1', title: 'Bob'),
    child: const Text('Bob'),
  );
}

void main() {
  late ChatFake chat;
  late ProviderContainer c;
  final showTile = ValueNotifier(true);

  Future<void> pump(WidgetTester t) async {
    showTile.value = true;
    chat = ChatFake(self: me.userId)
      ..history['c1'] = [chatMessage('m1')]
      ..conversationsResult = const Ok([
        Conversation(id: 'c1', title: 'Bob'),
        Conversation(id: 'c2', title: 'Work'),
      ]);
    c = await settled(
      ProviderContainer.test(
        overrides: [
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
          sessionControllerProvider.overrideWith(SignedInForTests.new),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        ],
      ),
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: sisTheme(Brightness.light),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showTile,
              builder: (_, show, _) =>
                  show ? const _Tile() : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  /// Opens c1 from the tile, then removes the tile while the chat is open.
  Future<void> openThenRemoveTile(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('tile-c1')));
    await settleImages(t);
    expect(find.byType(MessageScreen), findsOneWidget);
    showTile.value = false;
    await t.pump();
    expect(
      find.byKey(const ValueKey('tile-c1'), skipOffstage: false),
      findsNothing,
      reason: 'precondition: the calling tile is gone',
    );
  }

  testWidgets('leaving: markRead, close, reload -- with the tile gone', (
    t,
  ) async {
    await pump(t);
    await openThenRemoveTile(t);
    chat.calls.clear();
    chat.markedRead.clear();

    await osBack(t);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.byType(MessageScreen), findsNothing);
    expect(chat.markedRead, ['c1']);
    expect(c.read(openConversationProvider), isNull);
    final marked = chat.calls.indexOf('markRead:c1');
    final reloaded = chat.calls.lastIndexOf('conversations');
    expect(marked, isNot(-1));
    expect(reloaded, greaterThan(marked), reason: 'reload after markRead');
  });

  testWidgets('opened from inside another chat: that one comes back', (
    t,
  ) async {
    await pump(t);
    c.read(openConversationProvider.notifier).open('c2');
    await openThenRemoveTile(t);

    await osBack(t);
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(c.read(openConversationProvider), 'c2');
  });

  testWidgets('another chat opened during the leaving markRead stays open', (
    t,
  ) async {
    await pump(t);
    await openThenRemoveTile(t);
    chat.holdMarkRead();
    chat.calls.clear();

    await osBack(t);
    c.read(openConversationProvider.notifier).open('c2');
    chat.releaseMarkRead();
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(c.read(openConversationProvider), 'c2');
    expect(chat.calls, contains('conversations'), reason: 'still reloads');
  });
}
