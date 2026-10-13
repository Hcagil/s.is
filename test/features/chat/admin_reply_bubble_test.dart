// AdminReplyBubble against its two connections, wired as main.dart wires them
// (textSharerProvider, adminChatRepositoryProvider; adminAnswerProvider left
// to read the repository): the forward card copies and shares the invite, the
// confirm card answers through the repository, and each reply kind reads in
// English and Turkish. The fakes record what they were given and answer as the
// real ones can: Ok, a refusal, or late.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/admin_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/text_sharer.dart';
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';

import '../../support/l10n.dart';

class RecordingSharer implements TextSharer {
  final shared = <String>[];
  @override
  Future<void> share(String text) async => shared.add(text);
}

class RecordingAdminRepo implements AdminChatRepository {
  RecordingAdminRepo([this.reply = const Ok(null)]);
  final calls = <(String, bool)>[];
  Result<void> reply;
  Completer<Result<void>>? gate;
  @override
  Future<Result<void>> answer(String cardId, bool yes) async {
    calls.add((cardId, yes));
    if (gate != null) return gate!.future;
    return reply;
  }
}

const bot = '00000000-0000-0000-0000-00000000ad41';
Message adminMsg(Map<String, dynamic> m, {String id = 'card-1'}) => Message(
  id: id,
  conversationId: 'admin-conv',
  senderId: bot,
  body: '',
  createdAt: DateTime.utc(2026, 10, 13, 9),
  adminMsg: m,
);

Future<(RecordingSharer, RecordingAdminRepo)> pump(
  WidgetTester tester,
  Map<String, dynamic> m, {
  Locale locale = const Locale('en'),
  RecordingAdminRepo? repo,
}) async {
  final sharer = RecordingSharer();
  final r = repo ?? RecordingAdminRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        textSharerProvider.overrideWithValue(sharer),
        adminChatRepositoryProvider.overrideWithValue(r),
      ],
      child: localizedApp(
        locale: locale,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminReplyBubble(message: adminMsg(m)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (sharer, r);
}

/// Every Text and RichText on screen joined, so a line can be found whatever
/// widget splits it.
String screenText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
  for (final t in tester.widgetList<RichText>(find.byType(RichText)))
    t.text.toPlainText(),
].join('\n');

void main() {
  const link = 'https://play.test/optin';
  const email = 'pat@mail.test';

  for (final (locale, l) in [
    (const Locale('en'), l10nEn),
    (const Locale('tr'), l10nTr),
  ]) {
    group('${locale.languageCode}:', () {
      testWidgets('single-line kinds read their own words', (tester) async {
        final cases = <Map<String, dynamic>, String>{
          {'k': 'unk', 'help': true}: l.adminUnk,
          {'k': 'noem', 'help': true}: l.adminNoem,
          {'k': 'bad', 'help': true}: l.adminBad,
          {'k': 'rate'}: l.adminRate,
          {'k': 'keep'}: l.adminKeep,
          {'k': 'canOk'}: l.adminCanOk,
          {'k': 'nolink'}: l.adminNoLink,
          {'k': 'p3'}: l.adminP3,
          {'k': 'r3'}: l.adminR3,
          {'k': 'iosOk', 'e': 'i***@m***.test'}: l.adminIosOk('i***@m***.test'),
          {'k': 'andOk', 'e': 'p***@m***.test'}: l.adminAndOk('p***@m***.test'),
          {'k': 'rmOk', 'e': 'r***@m***.test'}: l.adminRmOk('r***@m***.test'),
          {'k': 'nolist', 'e': 'z***@m***.test', 'help': true}: l.adminNoList(
            'z***@m***.test',
          ),
        };
        for (final MapEntry(key: m, value: want) in cases.entries) {
          await pump(tester, m, locale: locale);
          expect(screenText(tester), contains(want), reason: 'k=${m['k']}');
        }
      });

      testWidgets('help:true adds the command list; a plain reply has none', (
        tester,
      ) async {
        await pump(tester, {'k': 'unk', 'help': true}, locale: locale);
        final withHelp = screenText(tester);
        for (final line in [
          l.adminHelpHeader,
          l.adminHelpIos,
          l.adminHelpAnd,
          l.adminHelpRm,
          l.adminHelpList,
        ]) {
          expect(withHelp, contains(line));
        }
        await pump(tester, {'k': 'canOk'}, locale: locale);
        expect(screenText(tester), isNot(contains(l.adminHelpHeader)));
      });

      testWidgets('list shows the counts and every full email, by platform', (
        tester,
      ) async {
        await pump(tester, {
          'k': 'list',
          'n': 4,
          'ios': ['ivy@mail.test'],
          'and': ['pat@mail.test', 'rob@mail.test'],
          'oth': ['zed@mail.test'],
        }, locale: locale);
        final s = screenText(tester);
        expect(s, contains(l.adminListHeader(4)));
        expect(s, contains(l.adminListIos(1)));
        expect(s, contains(l.adminListAnd(2)));
        expect(s, contains(l.adminListOther(1)));
        for (final e in [
          'ivy@mail.test',
          'pat@mail.test',
          'rob@mail.test',
          'zed@mail.test',
        ]) {
          expect(s, contains(e));
        }
      });
    });
  }

  group('forward card', () {
    testWidgets('Share hands the invite (link and email) to the share sheet', (
      tester,
    ) async {
      final (sharer, repo) = await pump(tester, {
        'k': 'fwd',
        'e': email,
        'l': link,
      });
      expect(screenText(tester), contains(l10nEn.adminFwdTitle));
      await tester.tap(find.text(l10nEn.adminShare));
      await tester.pumpAndSettle();
      expect(sharer.shared, [l10nEn.adminFwdBody(email, link)]);
      expect(repo.calls, isEmpty);
    });

    testWidgets('Share in Turkish shares the Turkish invite', (tester) async {
      final (sharer, _) = await pump(tester, {
        'k': 'fwd',
        'e': email,
        'l': link,
      }, locale: const Locale('tr'));
      await tester.tap(find.text(l10nTr.adminShare));
      await tester.pumpAndSettle();
      expect(sharer.shared, [l10nTr.adminFwdBody(email, link)]);
    });

    testWidgets(
      'Copy puts the same invite on the clipboard, and does not share',
      (tester) async {
        final copied = <String>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final (sharer, _) = await pump(tester, {
          'k': 'fwd',
          'e': email,
          'l': link,
        });
        await tester.tap(find.text(l10nEn.adminCopy));
        await tester.pump();
        expect(copied, [l10nEn.adminFwdBody(email, link)]);
        expect(sharer.shared, isEmpty);
        await tester.pumpAndSettle(const Duration(seconds: 5));
      },
    );
  });

  group('confirm card', () {
    final conf = {'k': 'conf', 'e': 'r***@m***.test'};

    testWidgets('shows the question, the masked address and both buttons', (
      tester,
    ) async {
      await pump(tester, conf);
      final s = screenText(tester);
      expect(s, contains(l10nEn.adminConfTitle));
      expect(s, contains(l10nEn.adminConfBody('r***@m***.test')));
      expect(find.text(l10nEn.adminConfYes), findsOneWidget);
      expect(find.text(l10nEn.adminConfNo), findsOneWidget);
    });

    testWidgets('Remove answers yes for this card, through the repository', (
      tester,
    ) async {
      final (sharer, repo) = await pump(tester, conf);
      await tester.tap(find.text(l10nEn.adminConfYes));
      await tester.pumpAndSettle();
      expect(repo.calls, [('card-1', true)]);
      expect(sharer.shared, isEmpty);
    });

    testWidgets('Cancel answers no for this card', (tester) async {
      final (_, repo) = await pump(tester, conf);
      await tester.tap(find.text(l10nEn.adminConfNo));
      await tester.pumpAndSettle();
      expect(repo.calls, [('card-1', false)]);
    });

    testWidgets('Turkish buttons answer the same way', (tester) async {
      final (_, repo) = await pump(tester, conf, locale: const Locale('tr'));
      await tester.tap(find.text(l10nTr.adminConfYes));
      await tester.pumpAndSettle();
      expect(repo.calls, [('card-1', true)]);
    });

    testWidgets('a refused answer (not the owner) does not throw', (
      tester,
    ) async {
      final (_, repo) = await pump(
        tester,
        conf,
        repo: RecordingAdminRepo(const Err(DeniedFailure())),
      );
      await tester.tap(find.text(l10nEn.adminConfYes));
      await tester.pumpAndSettle();
      expect(repo.calls, [('card-1', true)]);
      expect(tester.takeException(), isNull);
      await tester.pump(
        const Duration(seconds: 30),
      ); // let the refusal notice time out
    });

    testWidgets(
      'a late answer: the tap is sent at once, the card stays up until it lands',
      (tester) async {
        final slow = RecordingAdminRepo()..gate = Completer<Result<void>>();
        await pump(tester, conf, repo: slow);
        await tester.tap(find.text(l10nEn.adminConfYes));
        await tester.pump();
        expect(slow.calls, [('card-1', true)]);
        expect(screenText(tester), contains(l10nEn.adminConfTitle));
        slow.gate!.complete(const Ok(null));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    for (final (st, word) in [
      ('done', l10nEn.adminConfDone),
      ('cancelled', l10nEn.adminConfCancelled),
    ]) {
      testWidgets('st=$st shows "$word"', (tester) async {
        await pump(tester, {...conf, 'st': st});
        expect(screenText(tester), contains(word));
      });
    }

    testWidgets('st absent shows neither outcome word', (tester) async {
      await pump(tester, conf);
      final s = screenText(tester);
      expect(s, isNot(contains(l10nEn.adminConfDone)));
      expect(s, isNot(contains(l10nEn.adminConfCancelled)));
    });
  });
}
