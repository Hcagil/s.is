@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_contacts_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Contacts, exact-tag search, reach and picture privacy through the real
/// stack (v0.22.0): [SupabaseContactsRepository], [SupabaseChatRepository]
/// and [SupabaseProfileRepository] over clients signed in to a running local
/// Supabase, as `main.dart` builds them.
///
/// What only the real stack can show: that a find is what opens the way to a
/// stranger; that the lookup budgets hold under a burst of parallel calls
/// (the advisory lock, not the count alone); that the rate-limit error comes
/// back as the exact message the app shows; that what one member hides the
/// other really cannot read; and that an older build's queries still work.
///
/// Needs a freshly reset stack (`supabase db reset`), as CI has: ulas and
/// veli each spend a whole 10-minute budget, and selin's first add is
/// refused only while she and tuna share nothing.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
const _rateLimited = 'Too many searches, try again later.';

Future<SupabaseClient> signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

String freshTag(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

T ok<T>(Result<T> r) => switch (r) {
  Ok(:final value) => value,
  Err(:final failure) => fail('expected Ok, got ${failure.message}'),
};

final _jpegHead = base64Decode(
  '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////'
  '////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBAB'
  'AAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=',
);
PickedImage _jpeg(int tag) => PickedImage(
  bytes: Uint8List.fromList([..._jpegHead, tag, 0xFF, 0xD9]),
  contentType: 'image/jpeg',
  extension: 'jpg',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient selin, tuna, ulas, veli, yunus, zehra;
  String id(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    selin = await signedIn('selin@integration.test');
    tuna = await signedIn('tuna@integration.test');
    ulas = await signedIn('ulas@integration.test');
    veli = await signedIn('veli@integration.test');
    yunus = await signedIn('yunus@integration.test');
    zehra = await signedIn('zehra@integration.test');
  });

  tearDownAll(() async {
    for (final c in [selin, tuna, ulas, veli, yunus, zehra]) {
      await c.dispose();
    }
  });

  test('find by exact tag, save, chat, remove: through the real '
      'repositories', () async {
    final contacts = SupabaseContactsRepository(selin);
    final chat = SupabaseChatRepository(selin);
    final tunaTag = freshTag('tuna');
    ok(await SupabaseProfileRepository(tuna).save(tag: tunaTag));

    // A stranger: not among selin's people, and not someone she may save.
    expect(
      ok(await chat.members()).map((m) => m.userId),
      isNot(contains(id(tuna))),
    );
    expect(ok(await contacts.ids()), isNot(contains(id(tuna))));
    expect(
      await contacts.add(id(tuna)),
      isA<Err<void>>(),
      reason: 'saved a stranger nobody found',
    );
    expect(
      await chat.startDirectConversation(id(tuna)),
      isA<Err<String>>(),
      reason: 'started a chat with a stranger nobody found',
    );

    // Only an exact tag finds him; a prefix finds nobody.
    expect(ok(await contacts.findByTag(tunaTag.substring(0, 6))), isNull);
    final found = ok(await contacts.findByTag('@${tunaTag.toUpperCase()}'));
    expect(found, isA<Member>());
    expect(found!.userId, id(tuna));
    expect(found.tag, tunaTag);

    // The find opens the way: save (twice: idempotent), then he is one of
    // selin's people, then a chat.
    ok(await contacts.add(id(tuna)));
    ok(await contacts.add(id(tuna)));
    expect(ok(await contacts.ids()), contains(id(tuna)));
    expect(ok(await chat.members()).map((m) => m.userId), contains(id(tuna)));
    final conversation = ok(await chat.startDirectConversation(id(tuna)));
    expect(conversation, isNotEmpty);

    // Contacts are one-way: tuna did not save selin.
    expect(
      ok(await SupabaseContactsRepository(tuna).ids()),
      isNot(contains(id(selin))),
    );

    ok(await contacts.remove(id(tuna)));
    ok(await contacts.remove(id(tuna)));
    expect(ok(await contacts.ids()), isNot(contains(id(tuna))));
    // Still one of her people: they share a chat now.
    expect(ok(await chat.members()).map((m) => m.userId), contains(id(tuna)));
  });

  test('200 parallel finds: exactly 20 answered, the rest refused with '
      'the message the app shows', () async {
    final contacts = SupabaseContactsRepository(ulas);
    final results = await Future.wait([
      for (var i = 0; i < 200; i++) contacts.findByTag('nobody_$i'),
    ]);
    final answered = results.whereType<Ok<Member?>>().length;
    final refused = results.whereType<Err<Member?>>().toList();
    expect(answered, 20);
    expect(refused, hasLength(180));
    for (final r in refused) {
      expect(r.failure, isA<ProviderFailure>());
      expect(r.failure.message, _rateLimited);
    }
    // A separate budget: availability still answers.
    expect(
      ok(await SupabaseProfileRepository(ulas).isTagAvailable(freshTag('u'))),
      isTrue,
    );
  });

  test('200 parallel availability checks: exactly 60 answered', () async {
    final profiles = SupabaseProfileRepository(veli);
    final results = await Future.wait([
      for (var i = 0; i < 200; i++) profiles.isTagAvailable('free_tag_$i'),
    ]);
    expect(results.whereType<Ok<bool>>().length, 60);
    expect(results.whereType<Err<bool>>().length, 140);
    // A separate budget: finds still answer.
    expect(
      await SupabaseContactsRepository(veli).findByTag('nobody_at_all'),
      isA<Ok<Member?>>(),
    );
  });

  test('a picture hidden from a chat partner: path masked, object '
      'refused, until the owner saves her', () async {
    final zehraProfiles = SupabaseProfileRepository(zehra);
    final zehraContacts = SupabaseContactsRepository(zehra);
    final selinChat = SupabaseChatRepository(selin);

    // They share a chat (zehra finds selin to start it).
    final selinTag = ok(await SupabaseProfileRepository(selin).load()).tag;
    expect(ok(await zehraContacts.findByTag(selinTag))?.userId, id(selin));
    ok(await SupabaseChatRepository(zehra).startDirectConversation(id(selin)));
    ok(await zehraContacts.remove(id(selin)));

    final withPicture = ok(await zehraProfiles.setAvatar(_jpeg(7)));
    final path = withPicture.avatarPath!;
    ok(await zehraProfiles.save(avatarVisibility: AvatarVisibility.everyone));

    Member zehraAsSelinSees() => fail('unreachable');
    Future<Member> seen() async =>
        ok(await selinChat.members())
            .firstWhere((m) => m.userId == id(zehra), orElse: zehraAsSelinSees);

    expect((await seen()).avatarPath, path, reason: 'everyone');
    expect(ok(await selinChat.avatarBytes(path)), _jpeg(7).bytes);

    final hidden = ok(
      await zehraProfiles.save(avatarVisibility: AvatarVisibility.contacts),
    );
    expect(hidden.avatarVisibility, AvatarVisibility.contacts);
    expect(hidden.avatarPath, path, reason: 'the owner keeps her own path');
    expect(
      ok(await zehraProfiles.load()).avatarVisibility,
      AvatarVisibility.contacts,
      reason: 'the setting did not persist',
    );
    expect((await seen()).avatarPath, isNull, reason: 'contacts, not saved');
    final raw = await selin.storage
        .from('avatars')
        .list(path: 'profile/${id(zehra)}');
    expect(raw, isEmpty, reason: 'storage lists the hidden object');
    expect(
      await selinChat.avatarBytes(path),
      isA<Err<Uint8List>>(),
      reason: 'storage handed out a hidden picture',
    );

    ok(await zehraContacts.add(id(selin)));
    expect((await seen()).avatarPath, path, reason: 'contacts, saved');

    ok(await zehraProfiles.save(avatarVisibility: AvatarVisibility.nobody));
    expect((await seen()).avatarPath, isNull, reason: 'nobody');
    ok(await zehraContacts.remove(id(selin)));
    ok(await zehraProfiles.save(avatarVisibility: AvatarVisibility.everyone));
  });

  group('an older build still works', () {
    test('its profile reads return 2xx', () async {
      final me = id(yunus);
      final list = await yunus
          .from('profiles')
          .select('user_id, display_name, tag, avatar_path')
          .neq('user_id', me)
          .order('display_name');
      expect(list, isA<List<dynamic>>());
      final some = await yunus
          .from('profiles')
          .select('user_id, display_name, avatar_path')
          .inFilter('user_id', [me]);
      expect(some, hasLength(1));
      final own = await yunus
          .from('profiles')
          .select(
            'user_id, display_name, tag, onboarding_done, share_presence, '
            'share_typing, share_last_seen, share_read_status, avatar_path',
          )
          .eq('user_id', me)
          .single();
      expect(own['user_id'], me);
    });

    test('its profile writes, without avatar_visibility, return 2xx and '
        'land', () async {
      final me = id(yunus);
      const columns =
          'user_id, display_name, tag, onboarding_done, share_presence, '
          'share_typing, share_last_seen, share_read_status, avatar_path';
      final renamed = await yunus
          .from('profiles')
          .update({'display_name': 'Yunus Old'})
          .eq('user_id', me)
          .select(columns)
          .single();
      expect(renamed['display_name'], 'Yunus Old');

      // Sets a picture the old way: a new file, then avatar_path.
      final file = 'profile/$me/old-build.jpg';
      await yunus.storage
          .from('avatars')
          .uploadBinary(
            file,
            _jpeg(9).bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      final set = await yunus
          .from('profiles')
          .update({'avatar_path': file})
          .eq('user_id', me)
          .select(columns)
          .single();
      expect(set['avatar_path'], file);
      expect(
        ok(await SupabaseProfileRepository(yunus).load()).avatarPath,
        file,
        reason: 'the old-build write did not reach the real path',
      );

      // Someone else's folder is refused, and changes nothing.
      await expectLater(
        yunus
            .from('profiles')
            .update({'avatar_path': 'profile/${id(tuna)}/x.jpg'})
            .eq('user_id', me)
            .select(columns)
            .single(),
        throwsA(isA<PostgrestException>()),
      );
      expect(
        ok(await SupabaseProfileRepository(yunus).load()).avatarPath,
        file,
      );

      // Removes it the old way.
      final removed = await yunus
          .from('profiles')
          .update({'avatar_path': null})
          .eq('user_id', me)
          .select(columns)
          .single();
      expect(removed['avatar_path'], isNull);
      expect(
        ok(await SupabaseProfileRepository(yunus).load()).avatarPath,
        isNull,
      );
      await yunus.storage.from('avatars').remove([file]);
    });
  });
}
