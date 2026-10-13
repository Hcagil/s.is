import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_settings.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/poll.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';

const Member _member = Member(userId: 'u-d', displayName: 'Deniz');

Conversation _adminConv() =>
    Conversation(id: 'c-1', title: 'Admin', other: _member, isAdminChat: true);

Message _adminMsg() => Message(
  id: 'm-1',
  conversationId: 'c-1',
  senderId: 'u-d',
  body: 'Hello',
  createdAt: DateTime.utc(2026, 10, 7, 9),
  adminMsg: const {'k': 'unk', 'help': true},
);

void main() {
  test('adminPreviewPrefix is correct', () {
    expect(adminPreviewPrefix, equals('\u0001admin:'));
  });

  group('Conversation JSON and label', () {
    test('toJson writes isAdminChat only when true', () {
      final admin = _adminConv();
      final normal = Conversation(
        id: 'c-2',
        title: 'Chat',
        other: _member,
        isAdminChat: false,
      );

      final adminJson = admin.toJson();
      final normalJson = normal.toJson();

      expect(adminJson.containsKey('isAdminChat'), isTrue);
      expect(adminJson['isAdminChat'], isTrue);
      expect(normalJson.containsKey('isAdminChat'), isFalse);
    });

    test('fromJson round trip preserves isAdminChat flag', () {
      final admin = _adminConv();
      final normal = Conversation(
        id: 'c-2',
        title: 'Chat',
        other: _member,
        isAdminChat: false,
      );

      final adminRound = Conversation.fromJson(admin.toJson());
      final normalRound = Conversation.fromJson(normal.toJson());

      expect(adminRound.isAdminChat, isTrue);
      expect(normalRound.isAdminChat, isFalse);
    });

    test('label of an admin chat is SIS Admin', () {
      final admin = _adminConv();
      expect(admin.label, equals('SIS Admin'));
    });
  });

  group('Conversation copies keep isAdminChat', () {
    test('withArchived keeps isAdminChat', () {
      final conv = _adminConv();
      final updated = conv.withArchived(true);
      expect(updated.isAdminChat, isTrue);
    });

    test('withPinned keeps isAdminChat', () {
      final conv = _adminConv();
      final updated = conv.withPinned(true);
      expect(updated.isAdminChat, isTrue);
    });

    test('read keeps isAdminChat', () {
      final conv = _adminConv();
      final updated = conv.read();
      expect(updated.isAdminChat, isTrue);
    });

    test('withSettings keeps isAdminChat', () {
      final updated = _adminConv().withSettings(const GroupSettings());
      expect(updated.isAdminChat, isTrue);
    });

    test('withPinnedMessage keeps isAdminChat', () {
      final conv = _adminConv();
      final updated = conv.withPinnedMessage('msg');
      expect(updated.isAdminChat, isTrue);
    });

    test('withPreview keeps isAdminChat', () {
      final conv = _adminConv();
      final msg = Message(
        id: 'm-2',
        conversationId: 'c-1',
        senderId: 'u-d',
        body: 'Preview',
        createdAt: DateTime.utc(2026, 10, 7, 9),
      );
      final updated = conv.withPreview(msg);
      expect(updated.isAdminChat, isTrue);
    });
  });

  group('Message copies keep adminMsg', () {
    test('withLocalImage keeps adminMsg', () {
      final msg = _adminMsg();
      final updated = msg.withLocalImage(Uint8List.fromList([1, 2, 3]));
      expect(updated.adminMsg, equals(msg.adminMsg));
    });

    test('withPreview keeps adminMsg', () {
      final msg = _adminMsg();
      final updated = msg.withPreview(Uint8List.fromList([4, 5, 6]));
      expect(updated.adminMsg, equals(msg.adminMsg));
    });

    test('stored keeps adminMsg', () {
      final msg = _adminMsg();
      final updated = msg.stored();
      expect(updated.adminMsg, equals(msg.adminMsg));
    });
  });

  group('adminPreviewLine English', () {
    final l = lookupAppLocalizations(Locale('en'));

    test('unk with help', () {
      final result = adminPreviewLine(l, {'k': 'unk', 'help': true});
      expect(result, equals("I don’t know that command."));
      expect(result, isNot(contains('\n')));
    });

    test('noem with help', () {
      final result = adminPreviewLine(l, {'k': 'noem', 'help': true});
      expect(result, equals("That command needs an email address."));
    });

    test('rate', () {
      final result = adminPreviewLine(l, {'k': 'rate'});
      expect(result, equals("Too many commands. Wait a minute and try again."));
    });

    test('err with help', () {
      final result = adminPreviewLine(l, {'k': 'err', 'help': true});
      expect(result, equals("Something went wrong. Nothing was changed."));
    });

    test('keep', () {
      final result = adminPreviewLine(l, {'k': 'keep'});
      expect(result, equals("Cancelled: this card is no longer valid."));
    });

    test('canOk', () {
      final result = adminPreviewLine(l, {'k': 'canOk'});
      expect(result, equals("Cancelled. Nothing was removed."));
    });

    test('list', () {
      final result = adminPreviewLine(l, {
        'k': 'list',
        'n': 3,
        'ios': ['a@mail.test'],
        'and': ['b@mail.test'],
        'oth': ['c@mail.test'],
      });
      expect(result, equals("Testers: 3"));
    });

    test('fwd', () {
      final result = adminPreviewLine(l, {'k': 'fwd', 'e': 't***@m***.test'});
      expect(result, equals("Ready to forward"));
    });

    test('conf', () {
      final result = adminPreviewLine(l, {'k': 'conf', 'e': 't***@m***.test'});
      expect(result, equals("Remove this tester?"));
    });

    test('nolist with help', () {
      final result = adminPreviewLine(l, {
        'k': 'nolist',
        'e': 't***@m***.test',
        'help': true,
      });
      expect(result, equals("t***@m***.test is not on the tester list."));
    });

    test('unknown k does not throw', () {
      expect(() => adminPreviewLine(l, {'k': 'zzz'}), returnsNormally);
      final result = adminPreviewLine(l, {'k': 'zzz'});
      expect(result, isA<String>());
    });
  });

  group('adminPreviewLine Turkish', () {
    final l = lookupAppLocalizations(Locale('tr'));

    test('unk with help', () {
      final result = adminPreviewLine(l, {'k': 'unk', 'help': true});
      expect(result, equals("Bu komutu bilmiyorum."));
    });

    test('rate', () {
      final result = adminPreviewLine(l, {'k': 'rate'});
      expect(
        result,
        equals("Çok fazla komut. Bir dakika bekle ve tekrar dene."),
      );
    });

    test('list', () {
      final result = adminPreviewLine(l, {
        'k': 'list',
        'n': 2,
        'ios': [],
        'and': [],
        'oth': [],
      });
      expect(result, equals("Test kullanıcıları: 2"));
    });

    test('conf', () {
      final result = adminPreviewLine(l, {'k': 'conf', 'e': 'x'});
      expect(result, equals("Bu test kullanıcısı kaldırılsın mı?"));
    });

    test('canOk', () {
      final result = adminPreviewLine(l, {'k': 'canOk'});
      expect(result, equals("İptal edildi. Hiçbir şey kaldırılmadı."));
    });
  });
}
