// Chat search results read stored previews in the app language (same words as
// the chat list). Written from the contract (t_d914623597).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_location.dart';
import 'package:sis/features/chat/domain/video.dart';

import 'message_search_screens_test.dart' show World, type, byKey, settle;
import '../../support/l10n.dart';

Message _hit(String id, String body, int minute) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: body,
  createdAt: DateTime.utc(2026, 11, 3, 9, minute),
);

void main() {
  for (final (locale, words) in [
    (const Locale('en'), ['Location', 'Video', l10nEn.chatLockedMessage]),
    (const Locale('tr'), ['Konum', 'Video', l10nTr.chatLockedMessage]),
  ]) {
    testWidgets('search results in ${locale.languageCode}', (t) async {
      t.platformDispatcher.localesTestValue = [locale];
      addTearDown(t.platformDispatcher.clearLocalesTestValue);
      final w = World();
      w.chat.searchResult = Ok([
        _hit('s1', locationPreviewText, 1),
        _hit('s2', videoPreview, 2),
        _hit('s3', lockedBodyPlaceholder, 3),
      ]);
      await t.pumpWidget(w.app());
      await settle(t, 10);
      await type(t, 'list-search-field', 'abc');
      for (var i = 0; i < 3; i++) {
        final row = byKey('list-search-result-s${i + 1}');
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: row,
            matching: find.text(words[i], findRichText: true),
          ),
          findsOneWidget,
          reason: 'row ${i + 1}',
        );
      }
    });
  }
}
