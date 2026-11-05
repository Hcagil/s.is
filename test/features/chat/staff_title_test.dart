// A staff chat's name in the chat list, from the contract: the server's
// registry title in the app language; until the registry has the chat, the
// neutral l10n fallback. No built-in name.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/staff_registry.dart';
import 'package:sis/features/chat/presentation/conversation_tile.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

Future<void> _pump(
  WidgetTester t,
  Locale locale,
  StaffRegistryFake staff,
) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(staff: staff),
        chatRepositoryProvider.overrideWithValue(ChatFake(self: _me.userId)),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
      child: localizedApp(
        locale: locale,
        home: const Scaffold(
          body: ConversationTile(
            Conversation(
              id: 'c1',
              title: 'x',
              isAdminChat: true,
              staffKey: 'staff_a',
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final (locale, l, title) in [
    (const Locale('en'), l10nEn, 'Staff A'),
    (const Locale('tr'), l10nTr, 'Ekip A'),
  ]) {
    testWidgets('[${locale.languageCode}] registry title in the app language', (
      t,
    ) async {
      await _pump(t, locale, StaffRegistryFake(stored: neutralRegistry()));
      expect(find.text(title), findsOneWidget);
      expect(find.text(l.staffChatTitleFallback), findsNothing);
    });

    testWidgets(
      '[${locale.languageCode}] no registry yet: the neutral fallback',
      (t) async {
        await _pump(
          t,
          locale,
          StaffRegistryFake(refreshResult: const Ok(StaffRegistry.empty)),
        );
        expect(find.text(l.staffChatTitleFallback), findsOneWidget);
        expect(
          find.text('x'),
          findsNothing,
          reason: 'the raw row title is not shown',
        );
      },
    );
  }
}
