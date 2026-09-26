// PhotoManagerGallery's access answer and photo order, from the Gallery
// contract in
// lib/features/chat/domain/gallery.dart: Android never says "permanently
// denied", it silently stops prompting after the member has refused once.
// So a refusal after an earlier recorded ask is read as permanent, and the
// record lives in the preferences file so it survives the app restarting.
// recent() is newest first: Android's photo query has no order of its own
// worth trusting (it came back oldest first on the owner's phone), so the
// class must ask for creation date, descending.
//
// Runs the real class over photo_manager's platform channel and Android's
// preferences file (DiskPrefs): the device side, written from what the
// platform answers -- not from what the class expects of it.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/photo_manager_gallery.dart';
import 'package:sis/features/chat/domain/gallery.dart';

import '../../support/push_platform.dart';

/// photo_manager's PermissionState, by index, as its channel answers.
enum Platform { notDetermined, restricted, denied, authorized, limited }

/// One photo on the phone: its platform id, when it was added, and when it
/// was last edited (seconds).
class Shot {
  const Shot(this.id, this.added, this.edited);

  final String id;
  final int added;
  final int edited;
}

/// How photo_manager 3.12.0 names the date columns in a custom filter
/// (CustomColumns: Android MediaStore, then Darwin).
const _addedColumns = {'date_added', 'creationDate'};
const _editedColumns = {'date_modified', 'modificationDate'};

/// The first order an asset query asks for, as (date, ascending), from
/// photo_manager's channel payload: a classical FilterOptionGroup sends
/// `child.orders: [{type: OrderOptionType.index, asc}]`, a CustomFilter
/// sends `child.orderBy: [{column, isAsc}]`. Null when none is asked.
(String, bool)? firstOrder(Object? option) {
  final child = (option as Map?)?['child'] as Map?;
  final orders = (child?['orders'] as List?) ?? const [];
  if (orders.isNotEmpty) {
    final o = orders.first as Map;
    return (o['type'] == 0 ? 'added' : 'edited', o['asc'] as bool);
  }
  final orderBy = (child?['orderBy'] as List?) ?? const [];
  if (orderBy.isNotEmpty) {
    final o = orderBy.first as Map;
    final column = o['column'];
    final date = _addedColumns.contains(column)
        ? 'added'
        : _editedColumns.contains(column)
        ? 'edited'
        : '$column';
    return (date, o['isAsc'] as bool);
  }
  return null;
}

/// The photo library's platform side on one phone.
class PhotoPlatform {
  /// The phone's record of the permission.
  Platform state = Platform.notDetermined;

  /// What the member taps if a prompt is shown.
  Platform answer = Platform.denied;

  /// Android 11+ stops prompting once the member has refused twice; the
  /// answer is then whatever the record already says.
  int refusals = 0;

  int requests = 0;
  int settingsOpened = 0;

  /// The phone's photos in storage order: oldest first, which is what
  /// Android hands back when the query names no order.
  List<Shot> shots = const [];

  /// Every album-list request and every asset query, as sent.
  final List<MethodCall> albumCalls = [];
  final List<MethodCall> assetCalls = [];

  /// The shots as MediaStore sorts them for [option].
  List<Shot> _sorted(Object? option) {
    final order = firstOrder(option);
    final out = [...shots];
    if (order == null) return out; // storage order: the owner's bug
    final (date, asc) = order;
    int key(Shot s) => switch (date) {
      'added' => s.added,
      'edited' => s.edited,
      _ => 0, // an unknown column sorts nothing
    };
    out.sort((a, b) => asc ? key(a) - key(b) : key(b) - key(a));
    return out;
  }

  Map<String, Object?> _page(List<Shot> page) => {
    'data': [
      for (final s in page)
        {
          'id': s.id,
          'type': 1, // AssetType.image
          'width': 4000,
          'height': 3000,
          'createDt': s.added,
          'modifiedDt': s.edited,
        },
    ],
  };

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'getAssetPathList':
        albumCalls.add(call);
        return {
          'data': [
            {
              'id': 'isAll',
              'name': 'Recent',
              'isAll': true,
              'assetCount': shots.length,
            },
            if (args['onlyAll'] != true)
              {
                'id': 'camera',
                'name': 'Camera',
                'isAll': false,
                'assetCount': shots.length,
              },
          ],
        };
      case 'getAssetCountFromPath':
        return shots.length;
      case 'getAssetListPaged':
        assetCalls.add(call);
        final size = args['size'] as int;
        final all = _sorted(args['option']);
        final start = (args['page'] as int) * size;
        return _page(all.skip(start).take(size).toList());
      case 'getAssetListRange':
        assetCalls.add(call);
        final all = _sorted(args['option']);
        final start = args['start'] as int;
        return _page(
          all.skip(start).take((args['end'] as int) - start).toList(),
        );
      case 'requestPermissionExtend':
        requests++;
        if (state == Platform.authorized) return state.index;
        if (refusals >= 2) return state.index; // no prompt any more
        state = answer;
        if (state == Platform.denied) refusals++;
        return state.index;
      case 'getPermissionState':
        return state.index;
      case 'openSetting':
        settingsOpened++;
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  const prefs = MethodChannel('plugins.flutter.io/shared_preferences');
  late PhotoPlatform phone;
  late DiskPrefs disk;

  /// A new process on the same phone.
  void restart() => SharedPreferences.resetStatic();

  setUp(() {
    phone = PhotoPlatform();
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(photos, phone.handle);
    messenger.setMockMethodCallHandler(prefs, disk.handle);
    restart();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(photos, null);
    messenger.setMockMethodCallHandler(prefs, null);
  });

  test('allowed in full is full; a selection is limited', () async {
    phone.answer = Platform.authorized;
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.full,
    );

    phone = PhotoPlatform()..answer = Platform.limited;
    messenger.setMockMethodCallHandler(photos, phone.handle);
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.limited,
    );
  });

  test('the first refusal is plain denied: Android can still prompt', () async {
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.denied,
    );
    expect(phone.requests, 1);
  });

  test('refused again is permanently denied', () async {
    const gallery = PhotoManagerGallery();
    expect(await gallery.requestAccess(), GalleryAccess.denied);

    expect(
      await gallery.requestAccess(),
      GalleryAccess.permanentlyDenied,
      reason: 'Android will not prompt a second time: only settings help',
    );
  });

  test('the earlier ask is remembered across a restart', () async {
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.denied,
    );

    restart();

    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.permanentlyDenied,
      reason: 'the record of the first ask must live in the preferences file',
    );
  });

  test('a refusal on a phone that never asked before is not permanent, '
      'even after a restart', () async {
    restart();
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.denied,
    );
  });

  test('openSettings opens the app\'s page in the phone\'s settings', () async {
    await const PhotoManagerGallery().openSettings();
    expect(phone.settingsOpened, 1);
  });

  group('recent', () {
    // Added in this order: storage order is oldest first. Edits are in yet
    // another order, so sorting by the wrong date shows.
    const shots = [
      Shot('p-40', 1000, 9000),
      Shot('p-7', 2000, 1500),
      Shot('p-913', 3000, 8000),
      Shot('p-12', 4000, 1200),
      Shot('p-5', 5000, 3000),
    ];

    setUp(() {
      phone
        ..state = Platform.authorized
        ..answer = Platform.authorized
        ..shots = shots;
    });

    test(
      'asks the platform for the all-photos album, newest added first',
      () async {
        await const PhotoManagerGallery().recent();

        expect(phone.albumCalls, isNotEmpty);
        final album = phone.albumCalls.last.arguments as Map;
        expect(
          album['onlyAll'] == true || album['hasAll'] == true,
          isTrue,
          reason: 'the all-photos album must be in the answer',
        );
        expect(
          firstOrder(album['option']),
          ('added', false),
          reason:
              'the album must carry an explicit creation-date, descending '
              'order; got ${album['option']}',
        );

        expect(phone.assetCalls, isNotEmpty, reason: 'no asset query was sent');
        for (final call in phone.assetCalls) {
          final args = call.arguments as Map;
          expect(
            args['id'],
            'isAll',
            reason: 'photos from the all-photos album',
          );
          expect(
            firstOrder(args['option']),
            ('added', false),
            reason:
                'the asset query is where Android applies the order; '
                'got ${args['option']}',
          );
        }
      },
    );

    test('returns the newest photos first', () async {
      final photos = await const PhotoManagerGallery().recent();
      expect(photos.map((p) => p.id), ['p-5', 'p-12', 'p-913', 'p-7', 'p-40']);
    });

    test('count keeps the newest, not the oldest', () async {
      final photos = await const PhotoManagerGallery().recent(count: 2);
      expect(photos.map((p) => p.id), ['p-5', 'p-12']);
    });

    test('keeps the order the platform answered in', () async {
      // Whatever the platform sends back is the order shown: the class must
      // not re-sort it (ids here are neither numerically nor lexically
      // ordered, and the platform's answer is the source of truth).
      phone.shots = const [
        Shot('b', 10, 10),
        Shot('c', 20, 20),
        Shot('a', 30, 30),
      ];
      final photos = await const PhotoManagerGallery().recent();
      expect(photos.map((p) => p.id), ['a', 'c', 'b']);
    });
  });
}
