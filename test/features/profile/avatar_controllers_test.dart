// The two controllers that change a picture, over fakes written from the
// repository contracts: OwnProfileController.setAvatar / removeAvatar and
// ConversationListController.setGroupAvatar. Each passes the path it holds
// now as the one to delete, adopts the new state only on success, and keeps
// the old state (and says why) on failure.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final square = PickedImage(
  bytes: pngBytes,
  contentType: 'image/jpeg',
  extension: 'jpg',
);

OwnProfile maya({String? avatar}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  avatarPath: avatar,
);

Future<ProviderContainer> scope({ProfileFake? profile, ChatFake? chat}) =>
    settled(
      ProviderContainer.test(
        overrides: [
          profileRepositoryProvider.overrideWithValue(profile ?? ProfileFake()),
          chatRepositoryProvider.overrideWithValue(chat ?? ChatFake()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      ),
    );

void main() {
  group('OwnProfileController.setAvatar', () {
    test('uploads with no previous path when there is none, and adopts the '
        'new path', () async {
      final profile = ProfileFake(
        profile: maya(),
        latency: const Duration(milliseconds: 5),
      );
      final c = await scope(profile: profile);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);

      final r = await c.read(ownProfileProvider.notifier).setAvatar(square);

      expect(r, isA<Ok<OwnProfile>>());
      expect(profile.avatarUploads.single.previousPath, isNull);
      final path = c.read(ownProfileProvider).requireValue.avatarPath;
      expect(path, startsWith('profile/u1/'));
    });

    test('replacing passes the current path, so the old file is deleted, and '
        'the new path is never the old one', () async {
      final profile = ProfileFake(
        profile: maya(avatar: 'profile/u1/old.jpg'),
        bucket: {'profile/u1/old.jpg': pngBytes},
      );
      final c = await scope(profile: profile);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);

      await c.read(ownProfileProvider.notifier).setAvatar(square);
      final first = c.read(ownProfileProvider).requireValue.avatarPath;
      await c.read(ownProfileProvider.notifier).setAvatar(square);
      final second = c.read(ownProfileProvider).requireValue.avatarPath;

      expect(profile.avatarUploads.map((u) => u.previousPath), [
        'profile/u1/old.jpg',
        first,
      ]);
      expect(first, isNot('profile/u1/old.jpg'));
      expect(second, isNot(first));
      expect(profile.storedAvatars.keys, [second]);
    });

    test('a refused upload returns why and keeps the picture', () async {
      final profile = ProfileFake(profile: maya(avatar: 'profile/u1/old.jpg'))
        ..avatarResult = const Err(NetworkFailure('No connection'));
      final c = await scope(profile: profile);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);

      final r = await c.read(ownProfileProvider.notifier).setAvatar(square);

      expect((r as Err).failure.message, 'No connection');
      expect(
        c.read(ownProfileProvider).requireValue.avatarPath,
        'profile/u1/old.jpg',
      );
    });

    test('a later profile save keeps the picture '
        'the upload set', () async {
      final profile = ProfileFake(profile: maya());
      final c = await scope(profile: profile);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);

      await c.read(ownProfileProvider.notifier).setAvatar(square);
      final path = c.read(ownProfileProvider).requireValue.avatarPath;
      await c.read(ownProfileProvider.notifier).save(displayName: 'Maya K');

      expect(c.read(ownProfileProvider).requireValue.avatarPath, path);
    });
  });

  group('OwnProfileController.removeAvatar', () {
    test('deletes the current path and clears it', () async {
      final profile = ProfileFake(
        profile: maya(avatar: 'profile/u1/old.jpg'),
        bucket: {'profile/u1/old.jpg': pngBytes},
      );
      final c = await scope(profile: profile);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);

      final r = await c.read(ownProfileProvider.notifier).removeAvatar();

      expect(r, isA<Ok<OwnProfile>>());
      expect(profile.avatarRemovals, ['profile/u1/old.jpg']);
      expect(c.read(ownProfileProvider).requireValue.avatarPath, isNull);
      expect(profile.storedAvatars, isEmpty);
    });

    test('a refused removal returns why and keeps the picture', () async {
      final profile = ProfileFake(profile: maya(avatar: 'profile/u1/old.jpg'))
        ..avatarResult = const Err(NetworkFailure('No connection'));
      final c = await scope(profile: profile);
      c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);

      final r = await c.read(ownProfileProvider.notifier).removeAvatar();

      expect(r, isA<Err<OwnProfile>>());
      expect(
        c.read(ownProfileProvider).requireValue.avatarPath,
        'profile/u1/old.jpg',
      );
    });
  });

  group('ConversationListController.setGroupAvatar', () {
    ChatFake chatWith({String? groupAvatar}) =>
        ChatFake(latency: const Duration(milliseconds: 2))
          ..conversationsResult = Ok([
            Conversation(id: 'g1', title: 'Club', avatarPath: groupAvatar),
            const Conversation(id: 'c1', other: bob),
          ])
          ..avatarBucket = {?groupAvatar: pngBytes};

    test('sets it with the group\'s current path as the one to delete, and '
        'the list shows the new path', () async {
      final chat = chatWith(groupAvatar: 'group/g1/old.jpg');
      final c = await scope(chat: chat);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);

      final r = await c
          .read(conversationListProvider.notifier)
          .setGroupAvatar('g1', square);
      await pumpEventQueue();

      expect(r, isA<Ok<void>>());
      final call = chat.groupAvatarCalls.single;
      expect(call.conversationId, 'g1');
      expect(call.previousPath, 'group/g1/old.jpg');
      final row = c
          .read(conversationListProvider)
          .requireValue
          .singleWhere((x) => x.id == 'g1');
      expect(row.avatarPath, allOf(isNotNull, isNot('group/g1/old.jpg')));
      expect(chat.avatarBucket.keys, [row.avatarPath]);
    });

    test(
      'clearing passes null and the current path; the list shows none',
      () async {
        final chat = chatWith(groupAvatar: 'group/g1/old.jpg');
        final c = await scope(chat: chat);
        c.listen(conversationListProvider, (_, _) {});
        await c.read(conversationListProvider.future);

        await c
            .read(conversationListProvider.notifier)
            .setGroupAvatar('g1', null);
        await pumpEventQueue();

        final call = chat.groupAvatarCalls.single;
        expect(call.image, isNull);
        expect(call.previousPath, 'group/g1/old.jpg');
        expect(
          c
              .read(conversationListProvider)
              .requireValue
              .singleWhere((x) => x.id == 'g1')
              .avatarPath,
          isNull,
        );
      },
    );

    test('a refusal (a 1:1, or not a member) comes back as an Err and the '
        'list is unchanged', () async {
      final chat = chatWith(groupAvatar: 'group/g1/old.jpg');
      final c = await scope(chat: chat);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);

      final r = await c
          .read(conversationListProvider.notifier)
          .setGroupAvatar('c1', square);
      await pumpEventQueue();

      expect(r, isA<Err<void>>());
      expect((r as Err).failure, isA<DeniedFailure>());
      expect(chat.groupAvatarCalls.single.previousPath, isNull);
      expect(
        c
            .read(conversationListProvider)
            .requireValue
            .singleWhere((x) => x.id == 'g1')
            .avatarPath,
        'group/g1/old.jpg',
      );
    });
  });
}
