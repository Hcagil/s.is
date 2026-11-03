// chatPreviewLine: stored preview values become app-language words; isOpeningLast
// matches the chat's last message to a row still being opened. Written from the
// contract (t_d914623597), never from the implementation.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/presentation/conversation_tile.dart';

import '../../support/l10n.dart';

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
    test('"$stored" reads $en / $tr', () {
      expect(chatPreviewLine(l10nEn, stored), en);
      expect(chatPreviewLine(l10nTr, stored), tr);
    });
  }

  test('locked placeholder: opening vs could not be opened', () {
    expect(
      chatPreviewLine(l10nEn, lockedBodyPlaceholder, opening: true),
      'Opening message…',
    );
    expect(
      chatPreviewLine(l10nTr, lockedBodyPlaceholder, opening: true),
      'Mesaj açılıyor…',
    );
    expect(
      chatPreviewLine(l10nEn, lockedBodyPlaceholder),
      'This message could not be opened.',
    );
    expect(
      chatPreviewLine(l10nTr, lockedBodyPlaceholder),
      'Bu mesaj açılamadı.',
    );
  });

  test('opening does not change other texts', () {
    expect(chatPreviewLine(l10nTr, 'merhaba', opening: true), 'merhaba');
    expect(
      chatPreviewLine(l10nTr, locationPreviewText, opening: true),
      'Konum',
    );
  });

  group('isOpeningLast', () {
    final t = DateTime.utc(2026, 11, 3, 9);
    Message row(String conv, DateTime at) => Message(
      id: 'm',
      conversationId: conv,
      senderId: 'u2',
      body: lockedBodyPlaceholder,
      createdAt: at,
    );
    Conversation chat(DateTime? at) =>
        Conversation(id: 'c1', lastMessageAt: at);

    test('same chat and same time: true', () {
      expect(isOpeningLast([row('c1', t)], chat(t)), isTrue);
    });
    test('other chat: false', () {
      expect(isOpeningLast([row('c2', t)], chat(t)), isFalse);
    });
    test('other time: false', () {
      expect(
        isOpeningLast([row('c1', t.add(const Duration(seconds: 1)))], chat(t)),
        isFalse,
      );
    });
    test('no last time or nothing opening: false', () {
      expect(isOpeningLast([row('c1', t)], chat(null)), isFalse);
      expect(isOpeningLast(const [], chat(t)), isFalse);
    });
  });
}
