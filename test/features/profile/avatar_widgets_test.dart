// Profile and group pictures on screen, written from the contract:
//
//  - Settings > Profile: the avatar (profile-avatar) opens a SIS sheet with
//    "Choose photo" (avatar-choose: the app's own gallery sheet and its
//    permission explainer) and "Remove" (avatar-remove, only when a picture
//    is set). The picture is the gallery's 512 px square JPEG, a progress
//    line shows while it uploads, and a SIS notice reports the outcome.
//  - A group's page: the avatar (group-avatar) opens the same sheet for any
//    member; a 1:1's person page offers nothing of the kind.
//  - Wherever the initials circle shows, the picture shows once downloaded;
//    while it loads, when it cannot be read and when there is none, the
//    initials show instead -- never a blank, never a spinner.
//
// The whole app as main.dart mounts it; fakes only at the repository and
// gallery boundaries, one avatars "bucket" shared by both repositories as the
// one real bucket is. Run under TZ=JST-9 like every unit test.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/loading.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/initials.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/person_avatar.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/gallery_paging.dart' hide steps;
import '../../support/sis_ui.dart';

// Three real, distinct 4x4 PNGs: whose picture is shown is part of the check.
final red = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGM4IScHRwzEcQCxYxBBO0tjggAAAABJRU5ErkJggg==',
);
final green = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGOQOyEHRwzEcQCmwxBBaHAjlQAAAABJRU5ErkJggg==',
);
final blue = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGOQkzsBRwzEcQCcIxBBYbnFHgAAAABJRU5ErkJggg==',
);

const mePath = 'profile/u1/me.jpg';
const bobPath = 'profile/ub/bob.jpg';
const clubPath = 'group/g1/club.jpg';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

class World {
  World({bool pictures = false}) {
    final bob = Member(
      userId: 'ub',
      displayName: 'Bob Stone',
      tag: 'bobby',
      avatarPath: pictures ? bobPath : null,
    );
    final me = Member(
      userId: 'u1',
      displayName: 'Maya Kaya',
      tag: 'maya',
      avatarPath: pictures ? mePath : null,
    );
    const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');
    this.bob = bob;
    chat
      ..avatarBucket = bucket
      ..conversationsResult = Ok([
        Conversation(id: 'c1', other: bob, lastMessage: 'apple pie'),
        Conversation(
          id: 'g1',
          title: 'Club',
          lastMessage: 'yo',
          avatarPath: pictures ? clubPath : null,
        ),
      ])
      ..membersResult = Ok([bob, cem])
      ..roster['c1'] = [me, bob]
      ..roster['g1'] = [me, bob, cem]
      ..history['c1'] = [
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'ub',
          body: 'apple pie',
          createdAt: DateTime.utc(2026, 9, 20, 10),
        ),
      ]
      ..history['g1'] = [
        Message(
          id: 'm2',
          conversationId: 'g1',
          senderId: 'u3',
          body: 'yo',
          createdAt: DateTime.utc(2026, 9, 20, 11),
        ),
      ];
    if (pictures) {
      bucket[mePath] = red;
      bucket[bobPath] = green;
      bucket[clubPath] = blue;
    }
    profile = ProfileFake(
      bucket: bucket,
      profile: OwnProfile(
        userId: 'u1',
        displayName: 'Maya Kaya',
        tag: 'maya',
        onboardingDone: true,
        avatarPath: pictures ? mePath : null,
      ),
    );
  }

  late final Member bob;
  final bucket = <String, Uint8List>{};
  final chat = ChatFake(latency: const Duration(milliseconds: 2), self: 'u1');
  late final ProfileFake profile;
  final gallery =
      GalleryFake(photos: const [GalleryPhoto('p1'), GalleryPhoto('p2')])
        ..thumbnails['p1'] = photoPng
        ..thumbnails['p2'] = photoPng;
  final photos = AttachmentCacheFake();

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(
          session: true,
          member: const Member(userId: 'u1', displayName: 'Maya Kaya'),
        ),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      profileRepositoryProvider.overrideWithValue(profile),
      galleryProvider.overrideWithValue(gallery),
      attachmentCacheProvider.overrideWithValue(photos),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> settle(WidgetTester t) async {
  await steps(t);
  await settleImages(t);
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.pump();
  await t.tap(byKey(key));
  await settle(t);
}

/// Taps [f] and lets the call finish, without settling: the notice it
/// raises lives ~2 s, and settling would run it out before it is checked.
Future<void> act(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await steps(t);
}

Future<void> home(WidgetTester t, World w) async {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  await t.pumpWidget(w.app());
  await settle(t);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Future<void> back(WidgetTester t) async {
  await t.pageBack();
  await settle(t);
}

Future<void> openProfilePage(WidgetTester t) async {
  await tapKey(t, 'home-settings');
  await tapKey(t, 'settings-profile');
  expect(byKey('profile-avatar'), findsOneWidget);
}

Future<void> openGroupPage(WidgetTester t) async {
  await tapKey(t, 'conversation-g1');
  await tapKey(t, 'conversation-title');
  expect(find.byType(GroupScreen), findsOneWidget);
}

/// The image an image-bearing widget paints, unwrapped from any resize.
ImageProvider? _providerOf(Widget w) {
  ImageProvider? p;
  if (w is Image) {
    p = w.image;
  } else if (w is CircleAvatar) {
    p = w.foregroundImage ?? w.backgroundImage;
  } else if (w is DecoratedBox && w.decoration is BoxDecoration) {
    p = (w.decoration as BoxDecoration).image?.image;
  } else if (w is Container && w.decoration is BoxDecoration) {
    p = (w.decoration as BoxDecoration?)?.image?.image;
  } else if (w is Ink && w.decoration is BoxDecoration) {
    p = (w.decoration as BoxDecoration?)?.image?.image;
  }
  while (p is ResizeImage) {
    p = p.imageProvider;
  }
  return p;
}

/// The bytes of every picture painted in or under [scope].
List<Uint8List> picturesIn(Finder scope) => [
  for (final e
      in find
          .descendant(
            of: scope,
            matching: find.byWidgetPredicate((w) => _providerOf(w) != null),
            matchRoot: true,
          )
          .evaluate())
    if (_providerOf(e.widget) case final MemoryImage m) m.bytes,
];

/// The one avatar circle in [site].
Finder avatarIn(Finder site) => find
    .descendant(of: site, matching: find.byType(PersonAvatar), matchRoot: true)
    .first;

/// [site]'s avatar shows [bytes] -- that picture, and no other.
void expectPicture(Finder site, Uint8List bytes, String where) {
  final shown = picturesIn(avatarIn(site));
  expect(shown, isNotEmpty, reason: '$where: no picture shown');
  expect(
    shown.every((b) => listEquals(b, bytes)),
    isTrue,
    reason: '$where: the wrong picture is shown',
  );
}

/// [site]'s avatar shows [name]'s initials and nothing else: no picture, no
/// spinner, no SIS wait -- and it is not blank.
void expectInitials(Finder site, String name, String where) {
  final avatar = avatarIn(site);
  expect(picturesIn(avatar), isEmpty, reason: '$where: a picture is shown');
  expect(
    find.descendant(of: avatar, matching: find.text(initialsOf(name))),
    findsOneWidget,
    reason: '$where: no initials -- the circle is blank',
  );
  for (final spinner in [
    find.byType(CircularProgressIndicator),
    find.byType(SisLoadingLogo),
    find.byType(SisProgressLine),
  ]) {
    expect(
      find.descendant(of: avatar, matching: spinner),
      findsNothing,
      reason: '$where: a spinner stands in for the picture',
    );
  }
}

/// Walks every place an avatar circle shows, calling [check] at each with the
/// site, whose it is and the picture it should carry when loaded.
Future<void> everySite(
  WidgetTester t,
  void Function(Finder site, String name, Uint8List bytes, String where) check,
) async {
  check(byKey('conversation-c1'), 'Bob Stone', green, 'chat list, 1:1');
  check(byKey('conversation-g1'), 'Club', blue, 'chat list, group');

  // Chat-list search results.
  await t.enterText(
    find.descendant(
      of: byKey('list-search-field'),
      matching: find.byType(EditableText),
      matchRoot: true,
    ),
    'apple',
  );
  await steps(t, 30);
  await settleImages(t);
  final result = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('list-search-result-'),
  );
  expect(result, findsWidgets, reason: 'the search found nothing');
  check(result.first, 'Bob Stone', green, 'chat-list search result');
  await t.enterText(
    find.descendant(
      of: byKey('list-search-field'),
      matching: find.byType(EditableText),
      matchRoot: true,
    ),
    '',
  );
  await steps(t, 30);

  // The New chat picker.
  await t.tap(find.text('New chat'));
  await settle(t);
  check(byKey('member-ub'), 'Bob Stone', green, 'new chat picker');
  Navigator.of(t.element(byKey('member-ub'))).pop();
  await settle(t);

  // A 1:1: header, person page.
  await tapKey(t, 'conversation-c1');
  final header = find.descendant(
    of: find.byType(MessageScreen),
    matching: find.byType(AppBar),
  );
  check(header, 'Bob Stone', green, 'chat header, 1:1');

  // Forward sheet from that chat.
  await t.longPress(byKey('message-m1'));
  await settle(t);
  await t.tap(byKey('action-forward'));
  await settle(t);
  check(byKey('forward-g1'), 'Club', blue, 'forward sheet, group');
  await t.tapAt(const Offset(20, 20));
  await settle(t);

  await tapKey(t, 'conversation-title');
  check(find.byType(PersonScreen), 'Bob Stone', green, 'person page');
  await back(t);
  await back(t);

  // A group: header, page, member list.
  await tapKey(t, 'conversation-g1');
  final groupHeader = find.descendant(
    of: find.byType(MessageScreen),
    matching: find.byType(AppBar),
  );
  check(groupHeader, 'Club', blue, 'chat header, group');
  await tapKey(t, 'conversation-title');
  check(byKey('group-avatar'), 'Club', blue, 'group page');
  await tapKey(t, 'tab-members');
  check(byKey('group-member-ub'), 'Bob Stone', green, 'group member row');
  check(byKey('group-member-u1'), 'Maya Kaya', red, 'group member row, me');
  Navigator.of(t.element(find.byType(GroupScreen))).popUntil((r) => r.isFirst);
  await settle(t);

  // Settings: the card and the profile page.
  await tapKey(t, 'home-settings');
  check(byKey('settings-profile'), 'Maya Kaya', red, 'settings card');
  await tapKey(t, 'settings-profile');
  check(byKey('profile-avatar'), 'Maya Kaya', red, 'profile page');
}

void main() {
  group('pictures wherever the initials circle shows', () {
    testWidgets('downloaded: each site shows its owner\'s picture', (t) async {
      final w = World(pictures: true);
      await home(t, w);
      await everySite(t, (site, _, bytes, where) {
        expectPicture(site, bytes, where);
      });
    });

    testWidgets('still downloading: initials and tint everywhere, never a '
        'spinner or a blank', (t) async {
      final w = World(pictures: true);
      w.chat.holdAvatars();
      await home(t, w);
      expect(w.chat.avatarRequests, isNotEmpty, reason: 'nothing was asked');
      await everySite(t, (site, name, _, where) {
        expectInitials(site, name, where);
      });
      w.chat.releaseAvatars();
      await settle(t);
    });

    testWidgets('cannot be read: initials everywhere', (t) async {
      final w = World(pictures: true);
      for (final p in [mePath, bobPath, clubPath]) {
        w.chat.avatarFailures[p] = const NetworkFailure('No connection');
      }
      await home(t, w);
      await everySite(t, (site, name, _, where) {
        expectInitials(site, name, where);
      });
    });

    testWidgets('none set: initials everywhere, and nothing is downloaded', (
      t,
    ) async {
      final w = World();
      await home(t, w);
      await everySite(t, (site, name, _, where) {
        expectInitials(site, name, where);
      });
      expect(w.chat.avatarRequests, isEmpty);
    });
  });

  group('Settings > Profile: your own picture', () {
    testWidgets('with none set, the sheet offers Choose photo and no Remove; '
        'closing it changes nothing', (t) async {
      final w = World();
      await home(t, w);
      await openProfilePage(t);
      expectInitials(byKey('profile-avatar'), 'Maya Kaya', 'profile page');

      await tapKey(t, 'profile-avatar');
      expect(byKey('avatar-choose'), findsOneWidget);
      expect(byKey('avatar-remove'), findsNothing);
      await t.tapAt(const Offset(20, 20));
      await settle(t);
      expect(byKey('avatar-choose'), findsNothing);
      expect(w.profile.avatarUploads, isEmpty);
      expect(w.profile.avatarRemovals, isEmpty);
    });

    testWidgets('choosing a photo uploads its 512 px square JPEG with a '
        'progress line, reports it, and shows it here and on the card', (
      t,
    ) async {
      final w = World();
      await home(t, w);
      await openProfilePage(t);
      w.profile.holdAvatar();

      await tapKey(t, 'profile-avatar');
      await tapKey(t, 'avatar-choose');
      expect(
        byKey('sheet-photo-p1'),
        findsOneWidget,
        reason: 'the app\'s own gallery sheet did not open',
      );
      await t.tap(byKey('sheet-photo-p1'));
      await steps(t);

      expect(w.gallery.squareLoads, [
        (id: 'p1', size: 512),
      ], reason: 'not the 512 px square');
      expect(
        w.gallery.loadedIds,
        isEmpty,
        reason: 'the full-size photo was loaded instead of the square',
      );
      expect(
        find.byType(SisProgressLine),
        findsOneWidget,
        reason: 'no progress line while uploading',
      );
      expect(w.profile.avatarUploads, hasLength(1));
      final upload = w.profile.avatarUploads.single;
      expect(upload.image.contentType, 'image/jpeg');
      expect(upload.previousPath, isNull);

      w.profile.releaseAvatar();
      await steps(t);
      expect(find.byType(SisProgressLine), findsNothing);
      expect(
        noticeSaying('Profile picture updated'),
        findsOneWidget,
        reason: 'success is not reported',
      );
      expectPicture(byKey('profile-avatar'), pngBytes, 'profile page');
      await back(t);
      expectPicture(byKey('settings-profile'), pngBytes, 'settings card');
      await drainNotice(t);
    });

    testWidgets('replacing passes the current path so it can be deleted, '
        'and the new picture replaces the old on screen', (t) async {
      final w = World(pictures: true);
      await home(t, w);
      await openProfilePage(t);
      expectPicture(byKey('profile-avatar'), red, 'before');

      await tapKey(t, 'profile-avatar');
      expect(byKey('avatar-remove'), findsOneWidget);
      await tapKey(t, 'avatar-choose');
      await act(t, byKey('sheet-photo-p2'));

      final upload = w.profile.avatarUploads.single;
      expect(upload.previousPath, mePath);
      expect(noticeSaying('Profile picture updated'), findsOneWidget);
      expect(w.profile.profile.avatarPath, isNot(mePath));
      expect(w.bucket.containsKey(mePath), isFalse);
      expectPicture(byKey('profile-avatar'), pngBytes, 'after');
      await drainNotice(t);
    });

    testWidgets('Remove clears it: initials again, the stored file deleted', (
      t,
    ) async {
      final w = World(pictures: true);
      await home(t, w);
      await openProfilePage(t);

      await tapKey(t, 'profile-avatar');
      await act(t, byKey('avatar-remove'));
      expect(w.profile.avatarRemovals, [mePath]);
      expect(w.bucket.containsKey(mePath), isFalse);
      expect(
        noticeSaying('Profile picture removed'),
        findsOneWidget,
        reason: 'removal is not reported',
      );
      expectInitials(byKey('profile-avatar'), 'Maya Kaya', 'after remove');
      await back(t);
      expectInitials(byKey('settings-profile'), 'Maya Kaya', 'settings card');
      await drainNotice(t);
    });

    testWidgets('a failed upload says why in a SIS notice and keeps the '
        'picture that was there', (t) async {
      final w = World(pictures: true);
      w.profile.avatarResult = const Err(NetworkFailure('No connection'));
      await home(t, w);
      await openProfilePage(t);

      await tapKey(t, 'profile-avatar');
      await tapKey(t, 'avatar-choose');
      await act(t, byKey('sheet-photo-p1'));

      expect(noticeSaying('No connection'), findsOneWidget);
      expect(noticeSaying('Profile picture updated'), findsNothing);
      expect(find.byType(SisProgressLine), findsNothing);
      expectPicture(byKey('profile-avatar'), red, 'after a failed upload');
      expect(t.takeException(), isNull);
      await drainNotice(t);
    });

    testWidgets('a failed removal says why and keeps the picture', (t) async {
      final w = World(pictures: true);
      w.profile.avatarResult = const Err(NetworkFailure('No connection'));
      await home(t, w);
      await openProfilePage(t);

      await tapKey(t, 'profile-avatar');
      await act(t, byKey('avatar-remove'));
      expect(noticeSaying('No connection'), findsOneWidget);
      expect(noticeSaying('Profile picture removed'), findsNothing);
      expectPicture(byKey('profile-avatar'), red, 'after a failed removal');
      await drainNotice(t);
    });

    testWidgets('without photo access, Choose photo shows the existing '
        'explainer rather than an empty gallery', (t) async {
      final w = World();
      w.gallery.access = GalleryAccess.denied;
      await home(t, w);
      await openProfilePage(t);

      await tapKey(t, 'profile-avatar');
      await tapKey(t, 'avatar-choose');
      expect(byKey('sheet-allow'), findsOneWidget);
      expect(w.profile.avatarUploads, isEmpty);
    });
  });

  group('a group\'s picture', () {
    testWidgets('any member sets it from the group page: the square JPEG is '
        'sent for that group, and the page and the list show it', (t) async {
      final w = World();
      await home(t, w);
      await openGroupPage(t);
      expectInitials(byKey('group-avatar'), 'Club', 'group page');

      await tapKey(t, 'group-avatar');
      expect(byKey('avatar-remove'), findsNothing);
      await tapKey(t, 'avatar-choose');
      await act(t, byKey('sheet-photo-p1'));

      expect(w.gallery.squareLoads.single.size, 512);
      final call = w.chat.groupAvatarCalls.single;
      expect(call.conversationId, 'g1');
      expect(call.image?.contentType, 'image/jpeg');
      expect(call.previousPath, isNull);
      expect(noticeSaying('Group picture updated'), findsOneWidget);
      expectPicture(byKey('group-avatar'), pngBytes, 'group page');
      Navigator.of(t.element(find.byType(GroupScreen)))
          .popUntil((r) => r.isFirst);
      await settle(t);
      expectPicture(byKey('conversation-g1'), pngBytes, 'chat list');
      await drainNotice(t);
    });

    testWidgets('Remove shows only when set, and clears it with the old path', (
      t,
    ) async {
      final w = World(pictures: true);
      await home(t, w);
      await openGroupPage(t);

      await tapKey(t, 'group-avatar');
      await act(t, byKey('avatar-remove'));
      final call = w.chat.groupAvatarCalls.single;
      expect(call.conversationId, 'g1');
      expect(call.image, isNull);
      expect(call.previousPath, clubPath);
      expect(w.bucket.containsKey(clubPath), isFalse);
      expect(noticeSaying('Group picture removed'), findsOneWidget);
      expectInitials(byKey('group-avatar'), 'Club', 'after remove');
      await drainNotice(t);
    });

    testWidgets('a refused change says why and keeps the picture', (t) async {
      final w = World(pictures: true);
      w.chat.groupAvatarResult = const Err(DeniedFailure());
      await home(t, w);
      await openGroupPage(t);

      await tapKey(t, 'group-avatar');
      await tapKey(t, 'avatar-choose');
      await act(t, byKey('sheet-photo-p1'));

      expect(notice, findsOneWidget, reason: 'the refusal is not reported');
      expect(noticeSaying('Group picture updated'), findsNothing);
      expectPicture(byKey('group-avatar'), blue, 'after a refusal');
      expect(t.takeException(), isNull);
      await drainNotice(t);
    });

    testWidgets('a 1:1 has no picture of its own to change', (t) async {
      final w = World(pictures: true);
      await home(t, w);
      await tapKey(t, 'conversation-c1');
      await tapKey(t, 'conversation-title');
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(byKey('group-avatar'), findsNothing);

      await t.tap(avatarIn(find.byType(PersonScreen)));
      await settle(t);
      expect(byKey('avatar-choose'), findsNothing);
      expect(w.chat.groupAvatarCalls, isEmpty);
    });
  });

  group('the picture picker scrolls back past the newest photos', () {
    /// Settings > Profile > avatar > Choose photo, on a library of [n].
    Future<World> openOn(WidgetTester t, int n) async {
      final w = World();
      w.gallery.photos = photoLibrary(n);
      await home(t, w);
      await openProfilePage(t);
      await tapKey(t, 'profile-avatar');
      await tapKey(t, 'avatar-choose');
      expect(byKey('sheet-photo-p0'), findsOneWidget);
      return w;
    }

    testWidgets('opens on the first page; asks for the next only near the '
        'bottom', (t) async {
      final w = await openOn(t, 200);
      await expectNextPageOnlyNearBottom(t, w.gallery);
    });

    testWidgets('scrolls to the end, and a photo from the last page becomes '
        'the picture', (t) async {
      final w = await openOn(t, 2 * pageSize + 10);
      w.gallery.thumbnails['p129'] = photoPng;
      await expectPagesToEnd(t, w.gallery, 2 * pageSize + 10);

      await jumpToBottom(t);
      await settleImages(t);
      await act(t, byKey('sheet-photo-p129'));
      expect(w.gallery.squareLoads, [(id: 'p129', size: 512)]);
      expect(w.profile.avatarUploads, hasLength(1));
      await drainNotice(t);
    });

    testWidgets('a slow page shows the progress line and is asked for once', (
      t,
    ) async {
      final w = await openOn(t, 200);
      await expectSlowPage(t, w.gallery);
    });

    testWidgets('a failed page says so, keeps the photos, and is retried on '
        'the next scroll', (t) async {
      final w = await openOn(t, 200);
      await expectFailureAndRetry(t, w.gallery, 200);
    });
  });
}
