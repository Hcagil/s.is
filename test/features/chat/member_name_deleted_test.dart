import 'package:flutter_test/flutter_test.dart';
import 'package:sis/l10n/app_localizations_en.dart';
import 'package:sis/features/chat/presentation/member_name.dart';

void main() {
  final l = AppLocalizationsEn();

  test('a name is kept even when the id is reported deleted', () {
    expect(nameOrDeleted(l, 'Vic', 'v', {'v'}), equals('Vic'));
  });

  test('empty name and reported deleted shows Deleted account', () {
    expect(nameOrDeleted(l, '', 'v', {'v'}), equals('Deleted account'));
  });

  test('empty name and not reported shows Member', () {
    expect(nameOrDeleted(l, '', 'v', {'other'}), equals('Member'));
  });

  test('empty name with no reports shows Member', () {
    expect(nameOrDeleted(l, '', 'v', <String>{}), equals('Member'));
  });
}
