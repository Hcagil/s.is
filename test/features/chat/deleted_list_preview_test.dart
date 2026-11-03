// The chat list row of a chat whose last message was deleted for everyone
// reads the localized "This message was deleted" / "Bu mesaj silindi"
// (l10n quoteDeleted, t_5d6004ecdb), never the English stand-in in Turkish.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_tile.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');
const _bob = Member(userId: 'u2', displayName: 'Bob');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

Future<void> _pump(WidgetTester tester, Locale locale, String last) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(ChatFake(self: _me.userId)),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConversationTile(
            Conversation(
              id: 'c1',
              other: _bob,
              lastMessage: last,
              lastMessageAt: DateTime.utc(2026, 11, 3, 9),
              lastSenderId: _bob.userId,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _preview(String text) => find.descendant(
  of: find.byKey(const ValueKey('preview-c1')),
  matching: find.text(text, findRichText: true),
  matchRoot: true,
);

void main() {
  testWidgets('Turkish: "Bu mesaj silindi"', (tester) async {
    await _pump(tester, const Locale('tr'), deletedPreviewText);
    expect(_preview('Bu mesaj silindi'), findsOneWidget);
    expect(find.text('This message was deleted'), findsNothing);
  });

  testWidgets('English: "This message was deleted"', (tester) async {
    await _pump(tester, const Locale('en'), deletedPreviewText);
    expect(_preview('This message was deleted'), findsOneWidget);
  });

  testWidgets('an ordinary last message is shown as it is', (tester) async {
    await _pump(tester, const Locale('tr'), 'see you at nine');
    expect(_preview('see you at nine'), findsOneWidget);
    expect(find.text('Bu mesaj silindi'), findsNothing);
  });
}
