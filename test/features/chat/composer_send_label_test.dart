// The composer's send button carries an accessible label, Send / Gönder, so
// screen readers and tool/sis_test_send.sh find it by label, never by
// coordinates. Written from the contract, not from the widget's code.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> pump(WidgetTester tester, Locale locale) async {
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(ChatFake(self: me.userId)),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('composer-field')), 'hi');
  await tester.pumpAndSettle();
}

void main() {
  for (final (locale, label) in [
    (const Locale('en'), 'Send'),
    (const Locale('tr'), 'Gönder'),
  ]) {
    testWidgets('the send button is found by its label "$label"', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, locale);

      final byLabel = find.bySemanticsLabel(label);
      expect(byLabel, findsOneWidget);
      // The labelled node is the send button itself, not some other widget.
      expect(
        tester.getSemantics(find.byKey(const ValueKey('composer-send'))).label,
        label,
      );
      semantics.dispose();
    });
  }
}
