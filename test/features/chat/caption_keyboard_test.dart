import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/presentation/attachment_preview_page.dart';
import 'package:sis/features/chat/presentation/photo_ticks.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';

void main() {
  Future<void> open(WidgetTester t) async {
    await pumpLauncher(
      t,
      (context, _) => showAttachmentPreview(
        context,
        photos: const [GalleryPhoto('p1')],
        picked: PhotoTicks(),
        initial: 0,
      ),
      overrides: [
        galleryProvider.overrideWithValue(
          GalleryFake(photos: const [GalleryPhoto('p1')]),
        ),
      ],
    );
    expect(find.byType(AttachmentPreviewPage), findsOneWidget);
  }

  group('photo caption box', () {
    testWidgets('caption TextField has newline action and multiline type', (
      t,
    ) async {
      await open(t);
      final caption = find.byKey(const ValueKey('preview-caption'));
      expect(find.byType(AttachmentPreviewPage), findsOneWidget);
      final field = t.widget<TextField>(caption);
      expect(field.textInputAction, TextInputAction.newline);
      expect(field.keyboardType, TextInputType.multiline);
    });

    testWidgets('newline action does not send, keeps focus and text', (
      t,
    ) async {
      await open(t);
      final caption = find.byKey(const ValueKey('preview-caption'));
      await t.showKeyboard(caption);
      t.testTextInput.enterText('nice view');
      await t.pump();
      await t.testTextInput.receiveAction(TextInputAction.newline);
      await t.pump();
      expect(find.byType(AttachmentPreviewPage), findsOneWidget);
      final field = t.widget<TextField>(caption);
      expect(field.controller!.text, 'nice view');
      final editable = find.descendant(
        of: caption,
        matching: find.byType(EditableText),
      );
      final focusNode = t.widget<EditableText>(editable).focusNode;
      expect(FocusManager.instance.primaryFocus, focusNode);
    });
  });
}
