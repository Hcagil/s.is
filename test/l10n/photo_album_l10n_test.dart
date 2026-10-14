import 'package:flutter_test/flutter_test.dart';
import 'package:sis/l10n/app_localizations_en.dart';
import 'package:sis/l10n/app_localizations_tr.dart';

void main() {
  final en = AppLocalizationsEn();
  final tr = AppLocalizationsTr();

  test('messageActionDeletePhoto', () {
    expect(en.messageActionDeletePhoto, 'Delete this photo');
    expect(tr.messageActionDeletePhoto, 'Bu fotoğrafı sil');
  });

  test('messageActionDeleteForMe', () {
    expect(en.messageActionDeleteForMe, 'Delete for me');
    expect(en.messageActionDeleteForMe, isNot(en.messageActionDeletePhoto));
    expect(tr.messageActionDeleteForMe, isNot(tr.messageActionDeletePhoto));
  });

  test('messageActionDeleteForEveryone', () {
    expect(en.messageActionDeleteForEveryone, 'Delete for everyone');
    expect(
      en.messageActionDeleteForEveryone,
      isNot(en.messageActionDeletePhoto),
    );
    expect(
      tr.messageActionDeleteForEveryone,
      isNot(tr.messageActionDeletePhoto),
    );
  });

  test('messageDeleteAlbumTitle', () {
    expect(en.messageDeleteAlbumTitle, 'Delete this album?');
    expect(tr.messageDeleteAlbumTitle, 'Bu albüm silinsin mi?');
  });

  test('quotePhotos', () {
    expect(en.quotePhotos(3), '📷 3 photos');
    expect(tr.quotePhotos(7), '📷 7 fotoğraf');
    expect(en.quotePhotos(10), contains('10'));
  });
}
