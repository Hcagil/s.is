// The security code screens, written from the t_a9ef0f411f contract (QA
// contract: encryption row, page, mismatch sheet, unverify, changed line;
// corrected R3) and never from the implementation. Mounted as production
// mounts them (the app theme, every page through its own show*/open*
// function, chat_launcher.dart), the REAL securityCodeProvider and
// KeyDirectoryController in between, qa fakes only at the boundaries:
// the on-phone memory (security_code_fakes.dart) and the key server and
// signature check (key_directory_fakes.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/security_code_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/encryption_row.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/security_code_changed_line.dart';
import 'package:sis/features/chat/presentation/security_code_page.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/crypto/domain/security_code_store.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/chat_launcher.dart' hide me, bob;
import '../../support/fakes.dart';
import '../../support/key_directory_fakes.dart';
import '../../support/l10n.dart';
import '../../support/security_code_fakes.dart';

const meId = '00000000-0000-4000-8000-00000000000a';
const peerId = '00000000-0000-4000-8000-00000000000b';
const c11 = 'ERERERERERERERERERERERERERERERERERERERERERE=';
const e22 = 'IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=';
const c33 = 'MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=';
const e44 = 'REREREREREREREREREREREREREREREREREREREREREQ=';
const cSeq = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

/// The code of (me: c11/e22, peer: c33/e44), as 3 lines of 4 groups.
const lines = [
  '64123 10189 49145 77447',
  '26394 26382 08392 72117',
  '96311 91435 95244 00325',
];

/// The code once the peer's identity key is [cSeq]; its last line.
const seqLastLine = '38377 27280 48757 49977';

final t0 = DateTime.utc(2026, 9, 29, 10);

class _Me extends CurrentUserId {
  @override
  String? build() => meId;
}

ClaimedKeys dirKeys(String curve) => ClaimedKeys(
  identityKey: curve,
  signingKey: e44,
  deviceSignature: 'sig',
  oneTimeKey: '',
  isFallback: false,
);

class Rig {
  final KeyLog log = [];
  late final dir = FakeKeyDirectory(log)..identityAnswer = Ok(dirKeys(c33));
  late final engine = FakeEngine(log);
  final store = FakeSecurityCodeStore(
    own: const OwnKeys(curve25519: c11, ed25519: e22),
  )..sessions[peerId] = c33;

  List<Override> get overrides => [
    currentUserIdProvider.overrideWith(_Me.new),
    keyDirectoryProvider.overrideWithValue(dir),
    keyEngineProvider.overrideWithValue(engine),
    olmPickleStoreProvider.overrideWithValue(FakePickleStore(log)),
    pickleKeyStoreProvider.overrideWithValue(FakePickleKeys()),
    securityCodeStoreProvider.overrideWithValue(store),
  ];

  /// The peer's phone was replaced: a new session on the new key (the store
  /// clears the mark and records the change) and the directory follows.
  void keyChanged({DateTime? at}) {
    store.newSession(peerId, cSeq, at ?? t0.add(const Duration(minutes: 5)));
    dir.identityAnswer = Ok(dirKeys(cSeq));
  }
}

Future<void> go(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// Pops the page that holds [page] (the system back), then settles.
Future<void> back(WidgetTester t, Type page) async {
  Navigator.of(t.element(find.byType(page))).pop();
  await go(t);
}

AppLocalizations l10nOf(Locale l) => l.languageCode == 'tr' ? l10nTr : l10nEn;

/// The launcher opens the row on a page; the row opens the code page.
Future<void> pumpRow(WidgetTester t, Rig r, {Locale? locale}) async {
  await pumpLauncher(
    t,
    (context, ref) => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(
          body: EncryptionRow(userId: peerId, name: 'Bob'),
        ),
      ),
    ),
    locale: locale,
    overrides: r.overrides,
  );
  await go(t);
}

Future<void> pumpPage(WidgetTester t, Rig r, {Locale? locale}) async {
  await pumpLauncher(
    t,
    (context, ref) =>
        showSecurityCodePage(context, peerUserId: peerId, name: 'Bob'),
    locale: locale,
    overrides: r.overrides,
  );
  await go(t);
}

void expectCode(List<String> shown) {
  for (final line in shown) {
    expect(find.textContaining(line), findsOneWidget, reason: line);
  }
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    final l = l10nOf(locale);
    final lang = locale.languageCode;

    group('[$lang] security code page', () {
      testWidgets('ready: the 60 digits as 3 lines, Matches and Doesn\'t '
          'match, the new-phone note', (t) async {
        await pumpPage(t, Rig(), locale: locale);
        expect(find.byType(SecurityCodePage), findsOneWidget);
        expectCode(lines);
        expect(find.text(l.securityCodeMatches), findsOneWidget);
        expect(find.text(l.securityCodeDiffers), findsOneWidget);
        expect(find.text(l.securityCodeNewPhoneNote('Bob')), findsOneWidget);
        expect(find.text(l.securityCodeUnverify), findsNothing);
      });

      testWidgets('Matches marks the shown keys verified on this phone; the '
          'verified block with unverify replaces the buttons', (t) async {
        final r = Rig();
        await pumpPage(t, r, locale: locale);
        await t.tap(find.text(l.securityCodeMatches));
        await go(t);
        expect(
          r.store.marks[peerId],
          const VerifiedKeys(curve25519: c33, ed25519: e44),
        );
        expect(find.text(l.securityCodeVerifiedNote('Bob')), findsOneWidget);
        expect(find.text(l.securityCodeUnverify), findsOneWidget);
        expect(find.text(l.securityCodeMatches), findsNothing);
      });

      testWidgets('Doesn\'t match opens the mismatch sheet and marks nothing; '
          'OK closes it', (t) async {
        final r = Rig();
        await pumpPage(t, r, locale: locale);
        await t.tap(find.text(l.securityCodeDiffers));
        await go(t);
        expect(find.text(l.securityCodeMismatchTitle), findsOneWidget);
        expect(find.text(l.securityCodeMismatchBody('Bob')), findsOneWidget);
        expect(r.store.marks, isEmpty);
        await t.tap(find.text(l.securityCodeOk));
        await go(t);
        expect(find.text(l.securityCodeMismatchTitle), findsNothing);
        expect(find.text(l.securityCodeMatches), findsOneWidget);
        expect(r.store.marks, isEmpty);
      });

      testWidgets('unverify clears the mark and brings the buttons back', (
        t,
      ) async {
        final r = Rig()
          ..store.marks[peerId] = const VerifiedKeys(
            curve25519: c33,
            ed25519: e44,
          );
        await pumpPage(t, r, locale: locale);
        expect(find.text(l.securityCodeUnverify), findsOneWidget);
        await t.tap(find.text(l.securityCodeUnverify));
        await go(t);
        expect(r.store.marks, isEmpty);
        expect(find.text(l.securityCodeMatches), findsOneWidget);
        expect(find.text(l.securityCodeUnverify), findsNothing);
      });

      testWidgets('no session: no code, no buttons, the unavailable text', (
        t,
      ) async {
        final r = Rig()..store.sessions.clear();
        await pumpPage(t, r, locale: locale);
        expect(find.text(l.securityCodeUnavailable('Bob')), findsOneWidget);
        expect(find.textContaining(lines.first), findsNothing);
        expect(find.text(l.securityCodeMatches), findsNothing);
      });

      testWidgets('key mismatch: no code and no buttons', (t) async {
        final r = Rig()..dir.identityAnswer = Ok(dirKeys(cSeq));
        await pumpPage(t, r, locale: locale);
        expect(find.textContaining(lines.first), findsNothing);
        expect(find.text(l.securityCodeMatches), findsNothing);
      });
    });

    group('[$lang] encryption row', () {
      testWidgets('ready, not verified: the subtitle; a tap opens the page', (
        t,
      ) async {
        await pumpRow(t, Rig(), locale: locale);
        expect(find.text(l.encryptionRowTitle), findsOneWidget);
        expect(find.text(l.encryptionRowSubtitle), findsOneWidget);
        await t.tap(find.text(l.encryptionRowTitle));
        await go(t);
        expect(find.byType(SecurityCodePage), findsOneWidget);
        expectCode(lines);
      });

      testWidgets('verified: says Verified', (t) async {
        final r = Rig()
          ..store.marks[peerId] = const VerifiedKeys(
            curve25519: c33,
            ed25519: e44,
          );
        await pumpRow(t, r, locale: locale);
        expect(find.text(l.encryptionRowVerified), findsOneWidget);
      });

      testWidgets('no code: a tap opens nothing', (t) async {
        final r = Rig()..store.sessions.clear();
        await pumpRow(t, r, locale: locale);
        await t.tap(find.text(l.encryptionRowTitle), warnIfMissed: false);
        await go(t);
        expect(find.byType(SecurityCodePage), findsNothing);
      });
    });

    group('[$lang] security code changed line', () {
      Future<int> pumpLine(
        WidgetTester t, {
        required bool verifiedBefore,
      }) async {
        var taps = 0;
        await t.pumpWidget(
          localizedApp(
            locale: locale,
            home: Scaffold(
              body: SecurityCodeChangedLine(
                name: 'Bob',
                verifiedBefore: verifiedBefore,
                onTap: () => taps++,
              ),
            ),
          ),
        );
        await t.tap(find.byType(SecurityCodeChangedLine));
        return taps;
      }

      testWidgets('was verified: "no longer verified"; a tap reaches onTap', (
        t,
      ) async {
        expect(await pumpLine(t, verifiedBefore: true), 1);
        expect(
          find.text(l.securityCodeChangedUnverified('Bob')),
          findsOneWidget,
        );
      });

      testWidgets('never verified: the plain "changed" text', (t) async {
        expect(await pumpLine(t, verifiedBefore: false), 1);
        expect(find.text(l.securityCodeChanged('Bob')), findsOneWidget);
        expect(find.text(l.securityCodeChangedUnverified('Bob')), findsNothing);
      });
    });
  }

  group('seam: page, row and chat line over one memory', () {
    const peer = Member(userId: peerId, displayName: 'Bob');

    ChatFake directChat() => ChatFake(self: meId)
      ..history['c1'] = [
        chatMessage('m1', from: peerId, createdAt: t0),
        chatMessage(
          'm2',
          from: peerId,
          createdAt: t0.add(const Duration(minutes: 10)),
        ),
      ]
      ..roster['c1'] = [const Member(userId: meId, displayName: 'Maya'), peer]
      ..membersResult = const Ok([peer])
      ..conversationsResult = const Ok([Conversation(id: 'c1', other: peer)]);

    final changedUnverified = l10nEn.securityCodeChangedUnverified('Bob');
    final changedPlain = l10nEn.securityCodeChanged('Bob');

    Future<void> openChatC1(WidgetTester t, Rig r) async {
      await pumpLauncher(
        t,
        (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
        chat: directChat(),
        overrides: r.overrides,
      );
      await go(t);
      expect(find.byType(MessageScreen), findsOneWidget);
    }

    testWidgets('verify on the page -> the row says Verified -> the key '
        'changes -> the row is unverified with a new code and the chat shows '
        'the "no longer verified" line, whose tap opens the page', (t) async {
      final r = Rig();
      await pumpRow(t, r);
      await t.tap(find.text(l10nEn.encryptionRowTitle));
      await go(t);
      await t.tap(find.text(l10nEn.securityCodeMatches));
      await go(t);
      await back(t, SecurityCodePage);
      expect(find.text(l10nEn.encryptionRowVerified), findsOneWidget);

      r.keyChanged();
      await back(t, EncryptionRow); // leave the row page; open it again
      await t.tap(launcher);
      await go(t);
      expect(find.text(l10nEn.encryptionRowVerified), findsNothing);
      expect(find.text(l10nEn.encryptionRowSubtitle), findsOneWidget);
      await t.tap(find.text(l10nEn.encryptionRowTitle));
      await go(t);
      expect(find.textContaining(seqLastLine), findsOneWidget);
      expect(find.text(l10nEn.securityCodeMatches), findsOneWidget);
    });

    testWidgets('the chat: the "no longer verified" line between the '
        'messages; a tap opens the security code page', (t) async {
      final r = Rig()
        ..store.marks[peerId] = const VerifiedKeys(
          curve25519: c33,
          ed25519: e44,
        );
      r.keyChanged();
      await openChatC1(t, r);
      expect(find.text(changedUnverified), findsOneWidget);
      await t.tap(find.text(changedUnverified));
      await go(t);
      expect(find.byType(SecurityCodePage), findsOneWidget);
      expect(find.textContaining(seqLastLine), findsOneWidget);
    });

    testWidgets('never verified: the chat line has the plain wording', (
      t,
    ) async {
      final r = Rig()..keyChanged();
      await openChatC1(t, r);
      expect(find.text(changedPlain), findsOneWidget);
      expect(find.text(changedUnverified), findsNothing);
    });

    testWidgets('R3 (expected red, fix pending): re-verified for the new keys '
        '-> the same line drops "no longer verified" for the plain wording', (
      t,
    ) async {
      final r = Rig()
        ..store.marks[peerId] = const VerifiedKeys(
          curve25519: c33,
          ed25519: e44,
        );
      r.keyChanged();
      await openChatC1(t, r);
      expect(find.text(changedUnverified), findsOneWidget);
      await t.tap(find.text(changedUnverified));
      await go(t);
      await t.tap(find.text(l10nEn.securityCodeMatches));
      await go(t);
      expect(
        r.store.marks[peerId],
        const VerifiedKeys(curve25519: cSeq, ed25519: e44),
      );
      await back(t, SecurityCodePage);
      expect(find.text(changedPlain), findsOneWidget);
      expect(find.text(changedUnverified), findsNothing);
    });
  });
}
