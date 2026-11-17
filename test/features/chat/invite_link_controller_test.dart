import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/invite_link_controller.dart';

import '../../support/invite_link_fake.dart';

void main() {
  late InviteLinkFake fake;
  late ProviderContainer c;
  late InviteLinkController ctl;

  setUp(() {
    fake = InviteLinkFake(latency: Duration.zero)..admins.add('c1');
    c = ProviderContainer(
      overrides: [inviteLinkRepositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    ctl = c.read(inviteLinkControllerProvider);
  });

  Future<void> listenProvider(String conv) async {
    final sub = c.listen(inviteLinkProvider(conv), (_, _) {});
    addTearDown(sub.close);
  }

  group('reset', () {
    test('returns Ok with token length 24 and expiresAt not null', () async {
      await listenProvider('c1');
      final r = await ctl.reset('c1', validDays: 7);
      expect(r, isA<Ok>());
      final link = (r as Ok).value;
      expect(link.token.length, 24);
      expect(link.expiresAt, isNotNull);
      expect(fake.calls, contains('reset:c1:7'));
    });

    test('provider shows new link after reset', () async {
      await listenProvider('c1');
      expect(await c.read(inviteLinkProvider('c1').future), isNull);
      final r = await ctl.reset('c1', validDays: 7);
      expect(r, isA<Ok>());
      final link = (r as Ok).value;
      final p = await c.read(inviteLinkProvider('c1').future);
      expect(p, isNotNull);
      expect(p!.token, link.token);
      expect(fake.calls.where((x) => x == 'get:c1').length, 2);
    });

    test(
      'second reset gives different token and provider shows only new one',
      () async {
        await listenProvider('c1');
        final r1 = await ctl.reset('c1', validDays: 7);
        final t1 = (r1 as Ok).value.token;
        final r2 = await ctl.reset('c1', validDays: 7);
        final t2 = (r2 as Ok).value.token;
        expect(t1, isNot(equals(t2)));
        final p = await c.read(inviteLinkProvider('c1').future);
        expect(p!.token, t2);
      },
    );

    test('validDays null -> expiresAt null', () async {
      await listenProvider('c1');
      final r = await ctl.reset('c1');
      final link = (r as Ok).value;
      expect(link.expiresAt, isNull);
    });

    test('non-admin returns Err(DeniedFailure) and no refresh', () async {
      final r = await ctl.reset('c2', validDays: 7);
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<DeniedFailure>());
      expect(fake.calls, isNot(contains('get:c2')));
    });

    test('failNext = DeniedFailure -> Err and provider unchanged', () async {
      await listenProvider('c1');
      await c.read(inviteLinkProvider('c1').future);
      fake.failNext = const DeniedFailure();
      final r = await ctl.reset('c1', validDays: 7);
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<DeniedFailure>());
      expect(fake.calls.where((x) => x == 'get:c1').length, 1);
    });
  });

  group('turnOff', () {
    test('after reset, turnOff returns Ok and provider yields null', () async {
      await listenProvider('c1');
      await ctl.reset('c1', validDays: 7);
      expect(await c.read(inviteLinkProvider('c1').future), isNotNull);
      final r = await ctl.turnOff('c1');
      expect(r, isA<Ok>());
      final p = await c.read(inviteLinkProvider('c1').future);
      expect(p, isNull);
    });

    test('turnOff when no link exists is Ok', () async {
      await listenProvider('c1');
      final r = await ctl.turnOff('c1');
      expect(r, isA<Ok>());
    });

    test('turnOff as non-admin returns Err(DeniedFailure)', () async {
      final r = await ctl.turnOff('c2');
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<DeniedFailure>());
    });
  });

  group('join', () {
    test('join with a link address returns Ok and records join', () async {
      await listenProvider('c1');
      final rReset = await ctl.reset('c1', validDays: 7);
      final token = (rReset as Ok).value.token;
      final url = 'https://invite.sis.test/join/$token';
      final r = await ctl.join(url);
      expect(r, isA<Ok>());
      final conv = (r as Ok).value;
      expect(conv, equals('c1'));
      expect(fake.joined, contains('c1'));
      expect(fake.calls, contains('join:$token'));
    });

    test(
      'junk "hello" returns Err(InviteLinkFailure.invalid) and no call',
      () async {
        final r = await ctl.join('hello');
        expect(r, isA<Err>());
        final f = (r as Err).failure;
        expect(f, isA<InviteLinkFailure>());
        expect((f as InviteLinkFailure).problem, InviteLinkProblem.invalid);
        expect(fake.calls.where((x) => x.startsWith('join:')), isEmpty);
      },
    );

    test('expired link returns Err with problem expired', () async {
      await listenProvider('c1');
      final rReset = await ctl.reset('c1', validDays: 7);
      final token = (rReset as Ok).value.token;
      fake.expire('c1');
      final url = 'https://invite.sis.test/join/$token';
      final r = await ctl.join(url);
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<InviteLinkFailure>());
      expect((f as InviteLinkFailure).problem, InviteLinkProblem.expired);
    });

    test('closed group returns Err with problem closed', () async {
      await listenProvider('c1');
      final rReset = await ctl.reset('c1', validDays: 7);
      final token = (rReset as Ok).value.token;
      fake.closedGroups.add('c1');
      final url = 'https://invite.sis.test/join/$token';
      final r = await ctl.join(url);
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<InviteLinkFailure>());
      expect((f as InviteLinkFailure).problem, InviteLinkProblem.closed);
    });

    test('removed group returns Err with problem removed', () async {
      await listenProvider('c1');
      final rReset = await ctl.reset('c1', validDays: 7);
      final token = (rReset as Ok).value.token;
      fake.removedFrom.add('c1');
      final url = 'https://invite.sis.test/join/$token';
      final r = await ctl.join(url);
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<InviteLinkFailure>());
      expect((f as InviteLinkFailure).problem, InviteLinkProblem.removed);
    });

    test(
      'unknown 24-char code returns Err invalid but repository called',
      () async {
        final code = 'Q' * 24;
        final url = 'https://invite.sis.test/join/$code';
        final r = await ctl.join(url);
        expect(r, isA<Err>());
        final f = (r as Err).failure;
        expect(f, isA<InviteLinkFailure>());
        expect((f as InviteLinkFailure).problem, InviteLinkProblem.invalid);
        expect(fake.calls, contains('join:$code'));
      },
    );
  });

  group('preview', () {
    test(
      'preview with pasted address returns Ok with correct preview',
      () async {
        await listenProvider('c1');
        final rReset = await ctl.reset('c1', validDays: 7);
        final token = (rReset as Ok).value.token;
        fake.titles['c1'] = 'Team';
        final url = 'https://invite.sis.test/join/$token';
        final r = await ctl.preview(url);
        expect(r, isA<Ok>());
        final p = (r as Ok).value;
        expect(p.conversationId, equals('c1'));
        expect(p.title, equals('Team'));
        expect(p.memberCount, equals(2));
      },
    );

    test('junk returns Err invalid without preview call', () async {
      final r = await ctl.preview('hello');
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<InviteLinkFailure>());
      expect((f as InviteLinkFailure).problem, InviteLinkProblem.invalid);
      expect(fake.calls.where((x) => x.startsWith('preview:')), isEmpty);
    });

    test('removed group returns Err with problem removed', () async {
      await listenProvider('c1');
      final rReset = await ctl.reset('c1', validDays: 7);
      final token = (rReset as Ok).value.token;
      fake.removedFrom.add('c1');
      final url = 'https://invite.sis.test/join/$token';
      final r = await ctl.preview(url);
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<InviteLinkFailure>());
      expect((f as InviteLinkFailure).problem, InviteLinkProblem.removed);
    });

    test('failNext = DeniedFailure returns Err(DeniedFailure)', () async {
      fake.failNext = const DeniedFailure();
      final r = await ctl.preview(
        'https://invite.sis.test/join/QQQQQQQQQQQQQQQQQQQQQQQQ',
      );
      expect(r, isA<Err>());
      final f = (r as Err).failure;
      expect(f, isA<DeniedFailure>());
    });
  });
}
