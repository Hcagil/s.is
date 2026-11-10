// The chat list row reads stored previews in the app language, and a locked
// last message says "opening" only while the opener still waits for its
// session. Written from the contract (t_d914623597).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/presentation/conversation_tile.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';
import '../../support/l10n.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');
const _bob = Member(userId: 'u2', displayName: 'Bob');
final _at = DateTime.utc(2026, 11, 3, 9);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

class _Opening extends OpeningMessages {
  _Opening(this.rows);
  final List<Message> rows;
  @override
  List<Message> build() => rows;
}

Future<void> _pump(
  WidgetTester tester,
  Locale locale,
  String last, {
  List<Message> opening = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(ChatFake(self: _me.userId)),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        openingMessagesProvider.overrideWith(() => _Opening(opening)),
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
              lastMessageAt: _at,
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
  final cases = <(String, String, String)>[
    (photoPreviewText, 'Photo', 'Fotoğraf'),
    (videoPreview, 'Video', 'Video'),
    ('${filePreviewPrefix}report.pdf', 'File: report.pdf', 'Dosya: report.pdf'),
    (locationPreviewText, 'Location', 'Konum'),
    ('${contactPreviewPrefix}Ada', 'Contact: Ada', 'Kişi: Ada'),
    (stickerPreviewText, 'Sticker', 'Çıkartma'),
  ];
  for (final (stored, en, tr) in cases) {
    testWidgets('row for "$stored": $en / $tr', (t) async {
      await _pump(t, const Locale('en'), stored);
      expect(_preview(en), findsOneWidget);
      await _pump(t, const Locale('tr'), stored);
      expect(_preview(tr), findsOneWidget);
    });
  }

  final waiting = Message(
    id: 'm1',
    conversationId: 'c1',
    senderId: 'u2',
    body: lockedBodyPlaceholder,
    createdAt: _at,
  );

  testWidgets('a locked last message the opener waits on says opening', (
    t,
  ) async {
    await _pump(
      t,
      const Locale('en'),
      lockedBodyPlaceholder,
      opening: [waiting],
    );
    expect(_preview('Opening message…'), findsOneWidget);
    await _pump(
      t,
      const Locale('tr'),
      lockedBodyPlaceholder,
      opening: [waiting],
    );
    expect(_preview('Mesaj açılıyor…'), findsOneWidget);
  });

  testWidgets(
    'a locked last message nobody waits on says could not be opened',
    (t) async {
      await _pump(t, const Locale('en'), lockedBodyPlaceholder);
      expect(_preview(l10nEn.chatLockedMessage), findsOneWidget);
      await _pump(t, const Locale('tr'), lockedBodyPlaceholder);
      expect(_preview(l10nTr.chatLockedMessage), findsOneWidget);
    },
  );
}
