// Which links play inside SIS, and where an embedded player may go: the pure
// rules of lib/features/chat/domain/video_embed.dart, from the step 11b
// contract. Host tricks must never produce an embed.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/video_embed.dart';

const _id = 'dQw4w9WgXcQ'; // 11 characters
const _code = 'C1a2B3c4D5e';

VideoEmbed _embed(String link) => videoEmbedFor(Uri.parse(link))!;

void main() {
  test('site labels', () {
    expect(VideoSite.values.map((s) => s.label), [
      'YouTube',
      'Instagram',
      'TikTok',
      'X',
    ]);
  });

  group('YouTube', () {
    final nocookie = Uri.parse(
      'https://www.youtube-nocookie.com/embed/$_id?playsinline=1&autoplay=1&rel=0',
    );
    for (final link in [
      'https://youtu.be/$_id',
      'https://www.youtube.com/watch?v=$_id',
      'https://youtube.com/watch?v=$_id&t=42',
      'https://m.youtube.com/watch?v=$_id',
      'https://youtube.com/shorts/$_id',
      'https://www.youtube.com/embed/$_id',
      'https://www.youtube.com/live/$_id',
      'https://www.youtube-nocookie.com/embed/$_id',
    ]) {
      test('$link plays from youtube-nocookie with the app referer', () {
        final e = videoEmbedFor(Uri.parse(link));
        expect(e, isNotNull);
        expect(e!.site, VideoSite.youtube);
        expect(e.link, Uri.parse(link));
        expect(e.url, nocookie);
        expect(e.referer, 'https://com.esd.sis');
      });
    }

    for (final link in [
      'https://youtu.be/dQw4w9WgXc', // 10
      'https://youtu.be/dQw4w9WgXcQQ', // 12
      'https://www.youtube.com/watch?v=dQw4w9WgXc!',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQQ',
      'https://www.youtube.com/',
      'https://www.youtube.com/watch',
      'https://www.youtube.com/channel/$_id',
      'https://www.youtube.com/@someone',
    ]) {
      test('no embed for $link (bad or missing id)', () {
        expect(videoEmbedFor(Uri.parse(link)), isNull);
      });
    }
  });

  group('Instagram', () {
    for (final (path, kind) in [
      ('p', 'p'),
      ('reel', 'reel'),
      ('reels', 'reel'),
      ('tv', 'tv'),
    ]) {
      test('/$path/ becomes /$kind/<code>/embed/', () {
        final link = Uri.parse('https://www.instagram.com/$path/$_code/');
        final e = videoEmbedFor(link)!;
        expect(e.site, VideoSite.instagram);
        expect(e.link, link);
        expect(
          e.url,
          Uri.parse('https://www.instagram.com/$kind/$_code/embed/'),
        );
      });
    }
    test('a profile is not a video', () {
      expect(
        videoEmbedFor(Uri.parse('https://www.instagram.com/someone/')),
        isNull,
      );
    });
  });

  group('TikTok', () {
    for (final id in ['123456', '1' * 25, '7300000000000000000']) {
      test('a ${id.length}-digit id plays', () {
        final link = Uri.parse('https://www.tiktok.com/@user/video/$id');
        final e = videoEmbedFor(link)!;
        expect(e.site, VideoSite.tiktok);
        expect(e.link, link);
        expect(
          e.url,
          Uri.parse('https://www.tiktok.com/player/v1/$id?autoplay=1'),
        );
      });
    }
    for (final link in [
      'https://www.tiktok.com/@user/video/12345', // 5 digits
      'https://www.tiktok.com/@user/video/${'1' * 26}',
      'https://www.tiktok.com/@user/video/12345a7',
      'https://vm.tiktok.com/ZMabcdef/',
      'https://www.tiktok.com/@user',
    ]) {
      test('no embed for $link', () {
        expect(videoEmbedFor(Uri.parse(link)), isNull);
      });
    }
  });

  group('X', () {
    for (final host in ['x.com', 'twitter.com', 'www.twitter.com']) {
      test('$host/<user>/status/<id> becomes the Tweet embed', () {
        final link = Uri.parse('https://$host/user/status/1234567890');
        final e = videoEmbedFor(link)!;
        expect(e.site, VideoSite.x);
        expect(e.link, link);
        expect(
          e.url,
          Uri.parse(
            'https://platform.twitter.com/embed/Tweet.html?id=1234567890',
          ),
        );
      });
    }
    for (final link in [
      'https://x.com/user/status/abc',
      'https://x.com/user',
      'https://t.co/abc123',
    ]) {
      test('no embed for $link', () {
        expect(videoEmbedFor(Uri.parse(link)), isNull);
      });
    }
  });

  group('host tricks never produce an embed', () {
    for (final link in [
      'http://www.youtube.com/watch?v=$_id',
      'http://youtu.be/$_id',
      'https://a.youtube.com.evil.io/watch?v=$_id',
      'https://www.youtube.com.evil.io/watch?v=$_id',
      'https://youtu.be.evil.io/$_id',
      'https://evil.io/youtube.com/watch?v=$_id',
      'https://evil.io/?u=https://youtu.be/$_id',
      'https://youtube.com@evil.io/watch?v=$_id',
      // Contract: userinfo never produces an embed, even on the real host.
      'https://user@www.youtube.com/watch?v=$_id',
      'https://notyoutube.com/watch?v=$_id',
      'https://instagram.com.evil.io/p/$_code/',
      'https://evilinstagram.com/p/$_code/',
      'https://tiktok.com.evil.io/@u/video/123456',
      'https://x.com.evil.io/u/status/123',
      'https://eviltwitter.com/u/status/123',
      'ftp://youtu.be/$_id',
      'https://example.com/video.mp4',
    ]) {
      test(link, () => expect(videoEmbedFor(Uri.parse(link)), isNull));
    }
  });

  group('videoEmbedAllows', () {
    final yt = _embed('https://www.youtube.com/watch?v=$_id');

    test('the embed url itself loads as the main frame', () {
      expect(videoEmbedAllows(yt, yt.url, mainFrame: true), isTrue);
      expect(
        videoEmbedAllows(
          yt,
          Uri.parse('https://www.youtube-nocookie.com/embed/$_id?autoplay=1'),
          mainFrame: true,
        ),
        isTrue,
      );
    });

    test('a main frame leaving the embed path is refused', () {
      for (final t in [
        'https://www.youtube.com/watch?v=$_id',
        'https://www.youtube-nocookie.com/',
        'https://accounts.youtube.com/signin',
      ]) {
        expect(
          videoEmbedAllows(yt, Uri.parse(t), mainFrame: true),
          isFalse,
          reason: t,
        );
      }
    });

    test('a sub frame may load anywhere on the site domains', () {
      for (final t in [
        'https://www.youtube.com/watch?v=$_id',
        'https://youtube.com/',
        'https://i.ytimg.youtube-nocookie.com/x',
        'https://www.youtube-nocookie.com/',
      ]) {
        expect(
          videoEmbedAllows(yt, Uri.parse(t), mainFrame: false),
          isTrue,
          reason: t,
        );
      }
    });

    test('https only', () {
      final http = yt.url.replace(scheme: 'http');
      expect(videoEmbedAllows(yt, http, mainFrame: false), isFalse);
      expect(videoEmbedAllows(yt, http, mainFrame: true), isFalse);
      expect(
        videoEmbedAllows(
          yt,
          Uri.parse('javascript:alert(1)'),
          mainFrame: false,
        ),
        isFalse,
      );
    });

    test('other hosts and lookalikes are refused', () {
      for (final t in [
        'https://evil.io/',
        'https://youtube.com.evil.io/',
        'https://notyoutube.com/',
        'https://www.youtube-nocookie.com.evil.io/embed/$_id',
        'https://instagram.com/',
      ]) {
        expect(
          videoEmbedAllows(yt, Uri.parse(t), mainFrame: false),
          isFalse,
          reason: t,
        );
      }
    });

    for (final (link, ok, bad) in [
      (
        'https://www.instagram.com/p/$_code/',
        ['https://www.instagram.com/x', 'https://static.instagram.com/a.js'],
        [
          'https://notinstagram.com/',
          'https://www.youtube.com/',
          'https://x.com/',
        ],
      ),
      (
        'https://www.tiktok.com/@u/video/123456',
        ['https://www.tiktok.com/x', 'https://sf16.tiktok.com/a.js'],
        ['https://tiktok.com.evil.io/', 'https://instagram.com/'],
      ),
      (
        'https://x.com/u/status/123',
        [
          'https://platform.twitter.com/x',
          'https://x.com/x',
          'https://video.twitter.com/v',
        ],
        [
          'https://eviltwitter.com/',
          'https://x.com.evil.io/',
          'https://youtube.com/',
        ],
      ),
    ]) {
      test('domains for $link', () {
        final e = _embed(link);
        for (final t in ok) {
          expect(
            videoEmbedAllows(e, Uri.parse(t), mainFrame: false),
            isTrue,
            reason: t,
          );
        }
        for (final t in bad) {
          expect(
            videoEmbedAllows(e, Uri.parse(t), mainFrame: false),
            isFalse,
            reason: t,
          );
        }
        expect(videoEmbedAllows(e, e.url, mainFrame: true), isTrue);
        expect(
          videoEmbedAllows(e, Uri.parse(ok.first), mainFrame: true),
          isFalse,
          reason: 'main frame outside the embed path',
        );
      });
    }
  });

  group('refusalForStatus', () {
    for (final (status, refusal) in [
      (401, VideoRefusal.login),
      (403, VideoRefusal.isPrivate),
      (404, VideoRefusal.deleted),
      (410, VideoRefusal.deleted),
      (451, VideoRefusal.region),
      (400, VideoRefusal.other),
      (429, VideoRefusal.other),
      (500, VideoRefusal.other),
      (503, VideoRefusal.other),
    ]) {
      test('$status -> $refusal', () {
        expect(refusalForStatus(status), refusal);
      });
    }
  });
}
