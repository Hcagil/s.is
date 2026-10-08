import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';

class _Size {
  final int width;
  final int height;
  const _Size(this.width, this.height);

  @override
  bool operator ==(Object other) =>
      other is _Size && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

_Size _size(int w, int h) {
  final s = videoTargetSize(w, h);
  return _Size(s.width, s.height);
}

void main() {
  group('video.dart constants', () {
    test('maxVideoMs', () {
      expect(maxVideoMs, 300000);
    });
    test('videoShortSide', () {
      expect(videoShortSide, 720);
    });
    test('videoMime', () {
      expect(videoMime, 'video/mp4');
    });
    test('videoPreview', () {
      expect(videoPreview, '🎥 Video');
    });
  });

  group('video.dart functions', () {
    test('isVideoTooLong', () {
      expect(isVideoTooLong(299999), isFalse);
      expect(isVideoTooLong(300000), isFalse);
      expect(isVideoTooLong(300001), isTrue);
    });

    test('durationLabel', () {
      expect(durationLabel(41000), '0:41');
      expect(durationLabel(65400), '1:05');
      expect(durationLabel(0), '0:00');
      expect(durationLabel(300000), '5:00');
    });

    test('videoTargetSize', () {
      // Standard cases
      expect(_size(1920, 1080), _Size(1280, 720));
      expect(_size(1080, 1920), _Size(720, 1280));
      expect(_size(1280, 720), _Size(1280, 720));

      // No upscaling
      expect(_size(640, 360), _Size(640, 360));

      // Even rounding
      expect(_size(641, 361), _Size(640, 360));

      // Tiny sizes
      final tiny3 = _size(3, 3);
      expect(tiny3.width, greaterThanOrEqualTo(2));
      expect(tiny3.height, greaterThanOrEqualTo(2));
      expect(tiny3.width % 2, 0);
      expect(tiny3.height % 2, 0);

      final tiny1 = _size(1, 1);
      expect(tiny1.width, greaterThanOrEqualTo(2));
      expect(tiny1.height, greaterThanOrEqualTo(2));
      expect(tiny1.width % 2, 0);
      expect(tiny1.height % 2, 0);

      // Edge cases around 720
      expect(_size(720, 720), _Size(720, 720));
      expect(_size(721, 721), _Size(720, 720));
      expect(_size(721, 360), _Size(720, 360));
      expect(_size(721, 361), _Size(720, 360));
      expect(_size(721, 720), _Size(720, 720));
      expect(_size(720, 721), _Size(720, 720));
    });

    test('videoFileName', () {
      final original = 'Beach day.mov';
      final expected = '${safeFileName('Beach day')}.mp4';
      expect(videoFileName(original), expected);

      final clipMp4 = 'clip.MP4';
      final nameMp4 = videoFileName(clipMp4);
      expect(nameMp4.endsWith('.mp4'), isTrue);
      expect(nameMp4.contains('.MP4'), isFalse);

      final noExt = 'clip';
      final nameNoExt = videoFileName(noExt);
      expect(nameNoExt.endsWith('.mp4'), isTrue);
    });
  });

  group('VideoSource', () {
    final source = VideoSource(
      id: 'id',
      path: 'path',
      name: 'Beach day.mov',
      size: 12345,
      durationMs: 1000,
      width: 1920,
      height: 1080,
      thumbPath: 'thumb.png',
    );

    test('attached properties', () {
      final attached = source.attached;
      expect(attached.name, videoFileName('Beach day.mov'));
      expect(attached.mime, videoMime);
      expect(attached.size, 12345);
      expect(attached.durationMs, 1000);
      expect(attached.thumbPath, 'thumb.png');
      expect(attached.isVideo, isTrue);
    });
  });

  group('AttachedFile', () {
    test('isVideo true when durationMs present', () {
      final file = AttachedFile(
        name: 'video',
        mime: videoMime,
        size: 1000,
        durationMs: 500,
      );
      expect(file.isVideo, isTrue);
    });

    test('isVideo false when durationMs null', () {
      final file = AttachedFile(
        name: 'document',
        mime: 'application/pdf',
        size: 1000,
      );
      expect(file.isVideo, isFalse);
    });
  });

  group('PickedFile', () {
    test('attached keeps durationMs and thumbPath', () {
      final picked = PickedFile(
        id: 'id',
        path: 'path',
        name: 'video',
        mime: videoMime,
        size: 2000,
        durationMs: 2000,
        thumbPath: 'thumb.png',
      );
      final attached = picked.attached;
      expect(attached.durationMs, 2000);
      expect(attached.thumbPath, 'thumb.png');
    });
  });

  group('Message previewText', () {
    test('video file returns video preview', () {
      final msg = Message(
        id: 'id',
        conversationId: 'conv',
        senderId: 'sender',
        body: '',
        createdAt: DateTime.now(),
        file: AttachedFile(
          name: 'video',
          mime: videoMime,
          size: 1000,
          durationMs: 1000,
        ),
      );
      expect(previewText(msg), videoPreview);
    });

    test('non-video file does not return video preview', () {
      final msg = Message(
        id: 'id',
        conversationId: 'conv',
        senderId: 'sender',
        body: '',
        createdAt: DateTime.now(),
        file: AttachedFile(
          name: 'Cabin booking.pdf',
          mime: 'application/pdf',
          size: 1000,
        ),
      );
      expect(previewText(msg), isNot(videoPreview));
    });

    test('file with video mime but no durationMs is not video', () {
      final msg = Message(
        id: 'id',
        conversationId: 'conv',
        senderId: 'sender',
        body: '',
        createdAt: DateTime.now(),
        file: AttachedFile(name: 'trip.mp4', mime: videoMime, size: 1000),
      );
      expect(previewText(msg), isNot(videoPreview));
    });
  });

  group('VideoPick', () {
    test('default values', () {
      final pick = VideoPick();
      expect(pick.videos, isEmpty);
      expect(pick.tooLong, 0);
    });

    test('custom values', () {
      final source = VideoSource(
        id: 'id',
        path: 'path',
        name: 'video.mov',
        size: 1000,
        durationMs: 1000,
        width: 640,
        height: 360,
        thumbPath: 't.jpg',
      );
      final pick = VideoPick(videos: [source], tooLong: 5);
      expect(pick.videos.length, 1);
      expect(pick.tooLong, 5);
    });
  });

  group('VideoProgress', () {
    test('default fraction is 0', () {
      final progress = VideoProgress(VideoStage.compressing);
      expect(progress.fraction, 0);
      expect(progress.stage, VideoStage.compressing);
    });
  });
}
