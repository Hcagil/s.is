// nameOrMember, from the contract: the data layer returns '' for a member
// whose profile name is unknown; display turns that into the localised
// "Member". The rendered seam is in profile_pages_test ("an unknown name").
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/presentation/member_name.dart';

import '../../support/l10n.dart';

void main() {
  test('an empty name is the localised "Member"', () {
    expect(nameOrMember(l10nEn, ''), 'Member');
    expect(nameOrMember(l10nTr, ''), 'Üye');
  });

  test('a name is kept as it is, in either language', () {
    expect(nameOrMember(l10nEn, 'Bob'), 'Bob');
    expect(nameOrMember(l10nTr, 'Bob'), 'Bob');
    expect(nameOrMember(l10nEn, ' '), ' ', reason: 'not empty');
  });
}
