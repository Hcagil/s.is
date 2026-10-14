import 'dart:io';

import 'package:flutter/services.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;
import 'package:photo_manager/photo_manager.dart' show AssetEntity;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/photo_manager_video_gallery.dart';
import 'package:sis/features/chat/domain/file_repository.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/video_gallery.dart';

import '../../support/push_platform.dart';
import 'data/video_source_prep_test.dart' show TempFiles;
import 'photo_manager_gallery_test.dart' show firstOrder;

/// Fake DeviceFiles that records calls.
class NoFiles implements DeviceFiles {
  final calls = <String>[];
  @override
  noSuchMethod(Invocation i) {
    calls.add('${i.memberName}');
    throw UnimplementedError();
  }
}

/// One video on the phone: id, length in whole seconds, when added (seconds).
class Clip {
  const Clip(this.id, this.seconds, this.added);
  final String id;
  final int seconds;
  final int added;
}

/// Fake photo_manager platform channel.
class VideoPhone {
  int state =
      0; // 0 notDetermined, 1 restricted, 2 denied, 3 authorized, 4 limited
  int answer = 2; // what the member taps when prompted
  List<Clip> clips = const []; // storage order (oldest first)
  int thumbNulls = 0; // how many getThumb calls answer null before bytes come
  final calls = <MethodCall>[];

  /// What getFullFile answers per asset id: a real file path, or null for a
  /// video that lives only in iCloud. Unlisted ids answer null.
  final origins = <String, String?>{};

  /// Ids whose getFullFile answers with a platform error.
  final originThrows = <String>{};

  List<MethodCall> named(String m) =>
      calls.where((c) => c.method == m).toList();

  Map<String, Object?> _asset(Clip c) => {
    'id': c.id,
    'type': 2,
    'width': 1920,
    'height': 1080,
    'duration': c.seconds,
    'createDt': c.added,
    'modifiedDt': c.added,
  };

  /// What a query sees, in the order it asked for: without an order Android
  /// answers in storage order (oldest first), as on the owner's phone.
  List<Clip> _visible([Object? option]) {
    if (state != 3 && state != 4) return const [];
    final out = [...clips];
    final order = firstOrder(option);
    if (order == null) return out;
    final (date, asc) = order;
    if (date != 'added') return out;
    out.sort((a, b) => asc ? a.added - b.added : b.added - a.added);
    return out;
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'requestPermissionExtend':
        if (state != 3) state = answer;
        return state;
      case 'getPermissionState':
        return state;
      case 'getAssetPathList':
        return {
          'data': [
            {
              'id': 'isAll',
              'name': 'Recent',
              'isAll': true,
              'assetCount': _visible().length,
            },
          ],
        };
      case 'getAssetCountFromPath':
        return _visible().length;
      case 'getAssetListPaged':
        final size = args['size'] as int;
        final page = args['page'] as int;
        return {
          'data': [
            for (final c in _visible(
              args['option'],
            ).skip(page * size).take(size))
              _asset(c),
          ],
        };
      case 'fetchEntityProperties':
        for (final c in clips) {
          if (c.id == args['id']) return _asset(c);
        }
        return null;
      case 'getFullFile':
        if (originThrows.contains(args['id'])) {
          throw PlatformException(code: 'iCloud', message: 'download failed');
        }
        return origins[args['id']];
      case 'getThumb':
        if (thumbNulls > 0) {
          thumbNulls--;
          return null;
        }
        return Uint8List.fromList([1, 2, 3]);
      default:
        return null; // clearFileCache, openSetting, presentLimited ...
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  const prefs = MethodChannel('plugins.flutter.io/shared_preferences');
  late VideoPhone phone;
  late DiskPrefs disk;
  late NoFiles files;

  setUp(() {
    phone = VideoPhone();
    disk = DiskPrefs();
    files = NoFiles();
    messenger.setMockMethodCallHandler(photos, phone.handle);
    messenger.setMockMethodCallHandler(prefs, disk.handle);
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(photos, null);
    messenger.setMockMethodCallHandler(prefs, null);
  });

  PhotoManagerVideoGallery gallery() => PhotoManagerVideoGallery(files);

  group('requestAccess', () {
    test('authorized -> full', () async {
      phone.answer = 3;
      final access = await gallery().requestAccess();
      expect(access, GalleryAccess.full);
    });

    test('limited -> limited', () async {
      phone.answer = 4;
      final access = await gallery().requestAccess();
      expect(access, GalleryAccess.limited);
    });

    test('first refusal -> denied and flag set', () async {
      phone.answer = 2;
      final access = await gallery().requestAccess();
      expect(access, GalleryAccess.denied);
      expect(disk.values['flutter.gallery_permission_asked_before'], true);
    });

    test('second refusal -> permanentlyDenied', () async {
      phone.answer = 2;
      await gallery().requestAccess(); // first denial
      final access = await gallery().requestAccess(); // second denial
      expect(access, GalleryAccess.permanentlyDenied);
    });

    test('after restart still permanentlyDenied', () async {
      phone.answer = 2;
      await gallery().requestAccess(); // first denial
      await gallery().requestAccess(); // second denial
      SharedPreferences.resetStatic();
      final access = await gallery().requestAccess();
      expect(access, GalleryAccess.permanentlyDenied);
    });

    test('pre-asked flag -> permanentlyDenied immediately', () async {
      disk.values['flutter.gallery_permission_asked_before'] = true;
      final access = await gallery().requestAccess();
      expect(access, GalleryAccess.permanentlyDenied);
    });

    test('requestPermissionExtend arguments contain video type', () async {
      phone.answer = 3;
      await gallery().requestAccess();
      final call = phone.calls.firstWhere(
        (c) => c.method == 'requestPermissionExtend',
      );
      final args = call.arguments as Map;
      expect((args['androidPermission'] as Map)['type'], 2); // video
    });

    test('allowed after earlier refusal', () async {
      phone.answer = 2;
      await gallery().requestAccess(); // denied
      phone.answer = 3;
      phone.state = 0;
      final access = await gallery().requestAccess();
      expect(access, GalleryAccess.full);
    });
  });

  group('recent', () {
    setUp(() {
      phone.state = 3;
      phone.clips = const [
        Clip('a', 10, 100),
        Clip('b', 20, 300),
        Clip('c', 30, 200),
      ];
    });

    test('newest first by added date', () async {
      final videos = await gallery().recent();
      expect(videos.map((v) => v.id).toList(), ['b', 'c', 'a']);
      expect(videos.map((v) => v.durationMs).toList(), [20000, 30000, 10000]);
    });

    test('getAssetPathList called with video type', () async {
      await gallery().recent();
      final call = phone.calls.firstWhere(
        (c) => c.method == 'getAssetPathList',
      );
      final args = call.arguments as Map;
      expect(args['type'], 2);
    });

    test('paging works correctly', () async {
      phone.clips = List.generate(
        130,
        (i) => Clip('v$i', 5, i),
      ); // added ascending
      final page0 = await gallery().recent(page: 0, count: 60);
      expect(page0.length, 60);
      expect(page0.first.id, 'v129');
      final page2 = await gallery().recent(page: 2, count: 60);
      expect(page2.length, 10);
      expect(page2.last.id, 'v0');
      final page3 = await gallery().recent(page: 3, count: 60);
      expect(page3, isEmpty);
    });

    test('without access returns empty', () async {
      phone.state = 2; // denied
      final videos = await gallery().recent();
      expect(videos, isEmpty);
    });
  });

  group('thumbnail', () {
    setUp(() {
      phone.state = 3;
      phone.clips = const [Clip('a', 10, 100)];
    });

    test('first null then success', () async {
      phone.thumbNulls = 1;
      final video = GalleryVideo(id: 'a', durationMs: 1000);
      final thumb = await gallery().thumbnail(video);
      expect(thumb, isNotNull);
      expect(thumb, Uint8List.fromList([1, 2, 3]));
      final calls = phone.named('getThumb');
      expect(calls.length, 2);
    });

    test('many nulls -> null after retry', () async {
      phone.thumbNulls = 5;
      final video = GalleryVideo(id: 'a', durationMs: 1000);
      final thumb = await gallery().thumbnail(video);
      expect(thumb, isNull);
      final calls = phone.named('getThumb');
      expect(calls.length, 2);
    });

    test('unknown id returns null, no getThumb', () async {
      final video = GalleryVideo(id: 'gone', durationMs: 1000);
      final thumb = await gallery().thumbnail(video);
      expect(thumb, isNull);
      expect(phone.named('getThumb'), isEmpty);
    });

    test('size passed correctly', () async {
      final video = GalleryVideo(id: 'a', durationMs: 1000);
      await gallery().thumbnail(video, size: 300);
      final call = phone.calls.firstWhere((c) => c.method == 'getThumb');
      final option = call.arguments as Map;
      expect(option['option']['width'], 300);
      expect(option['option']['height'], 300);
    });
  });

  group('prepare', () {
    setUp(() {
      phone.state = 3;
    });

    test('unreadable video skipped', () async {
      final pick = await gallery().prepare([
        GalleryVideo(id: 'gone', durationMs: 1000),
      ]);
      expect(pick.videos, isEmpty);
      expect(pick.tooLong, 0);
      expect(phone.named('getFullFile'), isEmpty);
      expect(files.calls, isEmpty);
    });

    test('over 5 min counted as tooLong', () async {
      phone.clips = [Clip('long', 302, 1)];
      final pick = await gallery().prepare([
        GalleryVideo(id: 'long', durationMs: 302000),
      ]);
      expect(pick.tooLong, 1);
      expect(pick.videos, isEmpty);
      expect(phone.named('getFullFile'), isEmpty);
      expect(files.calls, isEmpty);
    });

    test('mixed videos all counted as tooLong', () async {
      phone.clips = [Clip('l1', 400, 1), Clip('l2', 3600, 2)];
      final pick = await gallery().prepare([
        GalleryVideo(id: 'l1', durationMs: 400000),
        GalleryVideo(id: 'gone', durationMs: 1000),
        GalleryVideo(id: 'l2', durationMs: 3600000),
      ]);
      expect(pick.tooLong, 2);
      expect(pick.videos, isEmpty);
    });

    test('file cache cleared after prepare', () async {
      phone.clips = [Clip('long', 302, 1)];
      await gallery().prepare([GalleryVideo(id: 'long', durationMs: 302000)]);
      final clearCalls = phone.named('clearFileCache');
      expect(clearCalls.length, 1);
      expect(phone.calls.last.method, 'clearFileCache');
    });

    test('empty list returns empty pick', () async {
      final pick = await gallery().prepare([]);
      expect(pick.videos, isEmpty);
      expect(pick.tooLong, 0);
    });

    test('an id that does not resolve counts 1 failed', () async {
      final pick = await gallery().prepare([
        GalleryVideo(id: 'gone', durationMs: 1000),
      ]);
      expect(pick.failed, 1);
      expect(pick.tooLong, 0);
      expect(pick.videos, isEmpty);
    });

    test('two unresolved ids count 2 failed', () async {
      final pick = await gallery().prepare([
        GalleryVideo(id: 'gone1', durationMs: 1000),
        GalleryVideo(id: 'gone2', durationMs: 1000),
      ]);
      expect(pick.failed, 2);
    });

    test('a too-long video counts only in tooLong', () async {
      phone.clips = [Clip('long', 302, 1)];
      final pick = await gallery().prepare([
        GalleryVideo(id: 'long', durationMs: 302000),
      ]);
      expect(pick.tooLong, 1);
      expect(pick.failed, 0);
    });

    test('too long and unresolved are counted apart', () async {
      phone.clips = [Clip('l1', 400, 1)];
      final pick = await gallery().prepare([
        GalleryVideo(id: 'l1', durationMs: 400000),
        GalleryVideo(id: 'gone', durationMs: 1000),
      ]);
      expect(pick.tooLong, 1);
      expect(pick.failed, 1);
      expect(pick.videos, isEmpty);
    });

    // A file read that errors (iCloud download failed) is a video that
    // could not be read: it must be counted, never swallowed. On this test
    // host photo_manager's originFile throws before the channel (it asserts
    // the platform), so the error arrives either way.
    test('an asset whose file read throws counts 1 failed', () async {
      phone.clips = [Clip('cloud', 10, 1)];
      phone.originThrows.add('cloud');
      final pick = await gallery().prepare([
        GalleryVideo(id: 'cloud', durationMs: 10000),
      ]);
      expect(pick.failed, 1);
      expect(pick.tooLong, 0);
      expect(pick.videos, isEmpty);
    });
  });

  group('settings', () {
    test('openSettings triggers openSetting', () async {
      await gallery().openSettings();
      final calls = phone.named('openSetting');
      expect(calls.length, 1);
    });
  });

  // The originFile seam: on this host photo_manager's own originFile asserts
  // the platform, so the phone's answer (a file, or null when the video lives
  // only in iCloud) is given here, and the real prepareVideoSource runs on it.
  group('prepare through the originFile seam', () {
    late Directory root;
    late MediaByContent compressor;
    late Map<String, File?> origins;
    late List<String> asked;

    setUp(() {
      phone.state = 3;
      root = Directory.systemTemp.createTempSync('gallery');
      compressor = MediaByContent(root);
      origins = {};
      asked = [];
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// A file the phone hands over, its first byte saying what it holds.
    File origin(String name, int kind) {
      final f = File('${root.path}/photos/$name');
      f.createSync(recursive: true);
      f.writeAsBytesSync([kind, 1, 2, 3]);
      return f;
    }

    PhotoManagerVideoGallery seamed() => PhotoManagerVideoGallery(
      TempFiles(root),
      compressor: compressor,
      originFile: (AssetEntity e) async {
        asked.add(e.id);
        return origins[e.id];
      },
    );

    test('null originFile (iCloud only) counts 1 failed', () async {
      phone.clips = [Clip('cloud', 10, 1)];
      origins['cloud'] = null;
      final pick = await seamed().prepare([
        GalleryVideo(id: 'cloud', durationMs: 10000),
      ]);
      expect(asked, ['cloud']);
      expect(pick.failed, 1);
      expect(pick.tooLong, 0);
      expect(pick.videos, isEmpty);
    });

    test('a good video goes into videos, with its extension', () async {
      phone.clips = [Clip('good', 10, 1)];
      origins['good'] = origin('IMG_0001.MOV', MediaByContent.readable);
      final pick = await seamed().prepare([
        GalleryVideo(id: 'good', durationMs: 10000),
      ]);
      expect(pick.failed, 0);
      expect(pick.tooLong, 0);
      expect(pick.videos, hasLength(1));
      expect(pick.videos.single.path.split('/').last, 'source.mov');
      expect(File(pick.videos.single.path).readAsBytesSync(), [
        MediaByContent.readable,
        1,
        2,
        3,
      ]);
      expect(compressor.probed.single.split('/').last, 'source.mov');
    });

    test('an .mp4 original is stored as source.mp4', () async {
      phone.clips = [Clip('m', 10, 1)];
      origins['m'] = origin('clip.mp4', MediaByContent.readable);
      final pick = await seamed().prepare([
        GalleryVideo(id: 'm', durationMs: 10000),
      ]);
      expect(pick.videos.single.path.split('/').last, 'source.mp4');
    });

    // A dot in a folder name is not an extension (iOS hands over files
    // under folders like com.apple.photos); the copy must still be found.
    test('an extensionless original in a dotted folder', () async {
      phone.clips = [Clip('plain', 10, 1)];
      final f = File('${root.path}/com.apple.photos/IMG_0004');
      f.createSync(recursive: true);
      f.writeAsBytesSync([MediaByContent.readable, 1, 2, 3]);
      origins['plain'] = f;
      final pick = await seamed().prepare([
        GalleryVideo(id: 'plain', durationMs: 10000),
      ]);
      expect(pick.failed, 0);
      expect(pick.videos, hasLength(1));
      final stored = pick.videos.single.path;
      expect(
        stored.split('/').last,
        Platform.isIOS ? 'source.mov' : 'source.mp4',
      );
      expect(stored, contains('/videos/${pick.videos.single.id}/'));
    });

    test(
      'unreadable media (prep null, not too long) counts 1 failed',
      () async {
        phone.clips = [Clip('bad', 10, 1)];
        origins['bad'] = origin('IMG_0002.MOV', MediaByContent.unreadable);
        final pick = await seamed().prepare([
          GalleryVideo(id: 'bad', durationMs: 10000),
        ]);
        expect(compressor.probed, hasLength(1));
        expect(pick.failed, 1);
        expect(pick.tooLong, 0);
        expect(pick.videos, isEmpty);
      },
    );

    test('too long by the media itself counts only in tooLong', () async {
      phone.clips = [Clip('long', 10, 1)]; // the library says 10 s
      origins['long'] = origin('IMG_0003.MOV', MediaByContent.sixMinutes);
      final pick = await seamed().prepare([
        GalleryVideo(id: 'long', durationMs: 10000),
      ]);
      expect(pick.tooLong, 1);
      expect(pick.failed, 0);
      expect(pick.videos, isEmpty);
    });

    test('mixed pick: each video counted once, the good ones kept', () async {
      phone.clips = [
        Clip('good1', 10, 1),
        Clip('cloud', 10, 2),
        Clip('bad', 10, 3),
        Clip('good2', 10, 4),
      ];
      origins['good1'] = origin('a.MOV', MediaByContent.readable);
      origins['cloud'] = null;
      origins['bad'] = origin('b.MOV', MediaByContent.unreadable);
      origins['good2'] = origin('c.mp4', MediaByContent.readable);
      final pick = await seamed().prepare([
        GalleryVideo(id: 'good1', durationMs: 10000),
        GalleryVideo(id: 'cloud', durationMs: 10000),
        GalleryVideo(id: 'gone', durationMs: 10000),
        GalleryVideo(id: 'bad', durationMs: 10000),
        GalleryVideo(id: 'good2', durationMs: 10000),
      ]);
      expect(pick.videos, hasLength(2));
      expect(pick.failed, 3);
      expect(pick.tooLong, 0);
      expect(pick.videos.map((v) => v.path.split('/').last).toList(), [
        'source.mov',
        'source.mp4',
      ]);
    });
  });
}

/// A LightCompressor fake whose answer depends on what the probed file holds,
/// as the real one does: first byte [readable], [unreadable] or [sixMinutes].
class MediaByContent implements lc.LightCompressor {
  MediaByContent(this.root);
  static const readable = 7;
  static const unreadable = 0;
  static const sixMinutes = 9;
  final Directory root;
  final probed = <String>[];
  int _thumbs = 0;

  @override
  Future<lc.MediaInfo> getMediaInfo(String path) async {
    probed.add(path);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final first = File(path).readAsBytesSync().first;
    if (first == unreadable) throw const lc.MediaInfoException();
    return lc.MediaInfo(
      duration: first == sixMinutes
          ? const Duration(minutes: 6)
          : const Duration(seconds: 10),
      width: 1920,
      height: 1080,
      fileSize: 4,
    );
  }

  @override
  Future<String> getVideoThumbnail(
    String path, {
    int positionInMs = 0,
    int quality = 50,
  }) async {
    final f = File('${root.path}/cache/shot${_thumbs++}.jpg');
    await f.create(recursive: true);
    await f.writeAsBytes([0xFF, 0xD8, 1, 2]);
    return f.path;
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
