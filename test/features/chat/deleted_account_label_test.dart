// The deleted account label test. Written from the contract (t_d914623597).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/conversation_tile.dart';
import 'package:sis/features/chat/presentation/member_name.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/auth/application/account_deletion_controller.dart';
import 'package:sis/features/auth/domain/account_deletion_repository.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/core/failure.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';
import '../../support/l10n.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');
final _at = DateTime.utc(2026, 11, 3, 9);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

class _Repo implements AccountDeletionRepository {
  _Repo(this.gone);
  final Set<String> gone;
  final asked = <String>[];
  @override
  Future<Result<DateTime>> requestDeletion() => throw UnimplementedError();
  @override
  Future<Result<Set<String>>> missingUsers(List<String> ids) async {
    asked.addAll(ids);
    return Ok(ids.where(gone.contains).toSet());
  }
}

void main() {
  // Unit tests for conversationLabel
  test('label for nameless deleted user', () {
    final conv = Conversation(
      id: 'c1',
      other: Member(userId: 'v', displayName: ''),
      lastMessage: 'x',
    );
    expect(
      conversationLabel(l10nEn, conv, deleted: {'v'}),
      l10nEn.deletedAccountName,
    );
  });

  test('label for nameless non-deleted user', () {
    final conv = Conversation(
      id: 'c1',
      other: Member(userId: 'v', displayName: ''),
      lastMessage: 'x',
    );
    expect(
      conversationLabel(l10nEn, conv, deleted: const {}),
      isNot(l10nEn.deletedAccountName),
    );
  });

  test('label for named deleted user', () {
    final conv = Conversation(
      id: 'c1',
      other: Member(userId: 'v', displayName: 'Vic'),
      lastMessage: 'x',
    );
    expect(conversationLabel(l10nEn, conv, deleted: {'v'}), 'Vic');
  });

  // Widget tests
  testWidgets(
    'nameless deleted user shows Deleted account label and is asked',
    (t) async {
      final conv = Conversation(
        id: 'c1',
        other: Member(userId: 'v', displayName: ''),
        lastMessage: 'hi',
        lastMessageAt: _at,
        lastSenderId: 'v',
      );
      final repo = _Repo({'v'});
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            ...videoOverrides(),
            chatRepositoryProvider.overrideWithValue(
              ChatFake(self: _me.userId),
            ),
            presenceRepositoryProvider.overrideWithValue(PresenceFake()),
            sessionControllerProvider.overrideWith(_SignedIn.new),
            accountDeletionRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: ConversationTile(conv)),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text(l10nEn.deletedAccountName), findsWidgets);
      expect(repo.asked, contains('v'));
    },
  );

  testWidgets('named user not deleted shows name and is not asked', (t) async {
    final conv = Conversation(
      id: 'c1',
      other: Member(userId: 'n', displayName: 'Nia'),
      lastMessage: 'hi',
      lastMessageAt: _at,
      lastSenderId: 'n',
    );
    final repo = _Repo({'n'});
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(ChatFake(self: _me.userId)),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(_SignedIn.new),
          accountDeletionRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ConversationTile(conv)),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Nia'), findsWidgets);
    expect(find.text(l10nEn.deletedAccountName), findsNothing);
    expect(repo.asked, isEmpty);
  });
}
