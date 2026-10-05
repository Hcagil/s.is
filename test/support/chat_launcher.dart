// The chat mounted the way production mounts it, for gesture tests: the
// app's own theme (sisTheme, whose page transition owns swipe-back), a phone
// sized view, a launcher page underneath, and every page opened through its
// own open*/show* function. Fakes only at the repository boundary.
//
// Fingers here move the way a phone delivers them: from mid-screen (an
// Android phone under gesture navigation keeps both edges for the system
// back gesture, so a drag from x = 5 never reaches the app), in many small
// moves with real timestamps (so the release velocity is what a phone
// measures, not the zero a timestamp-less drag reports).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import 'fakes.dart';


const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

final platforms = TargetPlatformVariant.only(TargetPlatform.android)
  ..values.add(TargetPlatform.iOS);

/// Signed in as [me].
class SignedInForTests extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Message chatMessage(
  String id, {
  String body = 'a message from bob, long enough to span a part of the row',
  String from = 'u2',
  DateTime? createdAt,
  bool pending = false,
  MessageDeletion? deletion,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: createdAt ?? DateTime.now(),
  localImage: pending ? pngBytes : null,
  deletion: deletion,
);

/// [n] messages from bob and me alternately, oldest first, newest 'm{n-1}'.
List<Message> manyMessages(int n) => [
  for (var i = 0; i < n; i++)
    chatMessage(
      'm$i',
      body: 'message number $i',
      from: i.isEven ? bob.userId : me.userId,
      createdAt: DateTime.now().subtract(Duration(minutes: n - i)),
    ),
];

/// A Pixel-class phone: 1080x2340 px at 2.625, 411x891 logical.
void phoneView(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
}

double screenWidth(WidgetTester t) =>
    t.view.physicalSize.width / t.view.devicePixelRatio;

double screenHeight(WidgetTester t) =>
    t.view.physicalSize.height / t.view.devicePixelRatio;

/// Pumps the app's theme around a launcher page on a phone-sized view;
/// [launch] opens whatever is under test from it. Returns the container.
Future<ProviderContainer> pumpLauncher(
  WidgetTester tester,
  void Function(BuildContext context, WidgetRef ref) launch, {
  List<Message>? messages,
  ChatFake? chat,
  bool tap = true,
}) async {
  phoneView(tester);
  final repo =
      chat ??
      (ChatFake(self: me.userId)
        ..history['c1'] = messages ?? [chatMessage('m1')]
        ..roster['c1'] = [me, bob, cem]
        ..membersResult = const Ok([bob, cem])
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', title: 'Bob'),
          Conversation(id: 'c2', title: 'Work'),
        ]));
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(repo),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(SignedInForTests.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      ],
    ),
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(Brightness.light),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('launch'),
                onPressed: () => launch(context, ref),
                child: const Text('launch'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (tap) {
    await tester.tap(find.byKey(const ValueKey('launch')));
    await settleImages(tester);
  }
  return container;
}

Finder bubble(String id) => find.byKey(ValueKey('message-$id'));
final launcher = find.byKey(const ValueKey('launch'));
final composer = find.byKey(const ValueKey('composer-field'));

/// Opens chat c1 through openConversation, as a chat-list tap does.
Future<ProviderContainer> openChat(
  WidgetTester tester, {
  List<Message>? messages,
}) async {
  final c = await pumpLauncher(
    tester,
    (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
    messages: messages,
  );
  expect(find.byType(MessageScreen), findsOneWidget, reason: 'never opened');
  return c;
}

/// Where the chat page's left edge is now: 0 at rest, > 0 while dragged.
double pageLeft(WidgetTester t) => t.getTopLeft(find.byType(MessageScreen)).dx;

bool composerFocused(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: composer, matching: find.byType(EditableText)),
    )
    .focusNode
    .hasFocus;

/// A finger put down at [from] and drawn by [by] in [steps] equal moves,
/// [over] in total, with a frame and a real timestamp per move. Returns the
/// finger still down unless [release].
Future<TestGesture> stroke(
  WidgetTester t,
  Offset from,
  Offset by, {
  Duration over = const Duration(milliseconds: 300),
  int steps = 15,
  bool release = true,
  Duration startAt = Duration.zero,
}) async {
  final g = await t.startGesture(from);
  await moveFinger(t, g, by, over: over, steps: steps, startAt: startAt);
  if (release) {
    await g.up(timeStamp: startAt + over);
  }
  return g;
}

/// Moves a finger already down by [by] in [steps] timed moves, starting at
/// [startAt] on the pointer clock.
Future<void> moveFinger(
  WidgetTester t,
  TestGesture g,
  Offset by, {
  Duration over = const Duration(milliseconds: 300),
  int steps = 15,
  Duration startAt = Duration.zero,
}) async {
  final step = over ~/ steps;
  for (var i = 1; i <= steps; i++) {
    await g.moveBy(by / steps.toDouble(), timeStamp: startAt + step * i);
    await t.pump(step);
  }
}

/// Lets a page transition and any images finish.
Future<void> settle(WidgetTester t) => settleImages(t);

/// The OS back button / back gesture without predictive back: the engine's
/// `popRoute` message on the navigation channel.
Future<void> osBack(WidgetTester t) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.navigation.name,
    SystemChannels.navigation.codec.encodeMethodCall(
      const MethodCall('popRoute'),
    ),
    (_) {},
  );
  await settle(t);
}

/// One predictive-back message (Android 14+), as the engine sends it.
Future<void> backGesture(
  WidgetTester t,
  String method, [
  double progress = 0,
]) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    SystemChannels.backGesture.codec.encodeMethodCall(
      MethodCall(
        method,
        method == 'commitBackGesture' || method == 'cancelBackGesture'
            ? null
            : <String, Object?>{
                'touchOffset': <double>[0, 400],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (_) {},
  );
  await t.pump();
}

/// The keyboard as the engine reports it: a bottom inset of [height]
/// logical px (0 = hidden).
Future<void> keyboardInset(WidgetTester t, double height) async {
  t.view.viewInsets = FakeViewPadding(bottom: height * t.view.devicePixelRatio);
  await t.pump();
  await t.pump();
}

/// Every HapticFeedback call the app makes, by type.
List<String> recordHaptics(WidgetTester tester) {
  final calls = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      calls.add(call.arguments as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}
