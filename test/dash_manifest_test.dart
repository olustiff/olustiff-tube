import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/core/playback/stream_selection.dart';

VideoStreamInfo stream({
  required int height,
  required int bitrate,
  int itag = 137,
  String codec = 'avc1.640028',
  String mimeType = 'video/mp4',
  String? url,
  int fps = 30,
  int initStart = 0,
  int initEnd = 739,
  int indexStart = 740,
  int indexEnd = 1231,
}) {
  return VideoStreamInfo(
    url: url ?? 'https://r1.test/videoplayback?itag=$itag',
    resolution: '${height}p',
    format: 'MPEG-4',
    isVideoOnly: true,
    fps: fps,
    bitrate: bitrate,
    mimeType: mimeType,
    codec: codec,
    itag: itag,
    width: (height * 16 / 9).round(),
    height: height,
    initStart: initStart,
    initEnd: initEnd,
    indexStart: indexStart,
    indexEnd: indexEnd,
  );
}

void main() {
  group('buildDashManifest', () {
    test('her çözünürlük için bir Representation üretilir', () {
      final manifest = buildDashManifest(
        [
          stream(height: 1080, bitrate: 4000000, itag: 137),
          stream(height: 720, bitrate: 2000000, itag: 136),
          stream(height: 360, bitrate: 600000, itag: 134),
        ],
        durationSeconds: 212,
      );

      expect(manifest, isNotNull);
      expect('<Representation '.allMatches(manifest!).length, 3);
      expect(manifest, contains('mediaPresentationDuration="PT212S"'));
      expect(manifest, contains('type="static"'));
      expect(manifest, contains('itag=137'));
      expect(manifest, contains('<SegmentBase indexRange="740-1231">'));
      expect(manifest, contains('<Initialization range="0-739"/>'));
    });

    test('temsilciler bant genişliğine göre artan sırada yazılır', () {
      // Oynatıcı ilk parçayı listenin başındakinden çekiyor; açılışın
      // takılmaması için en düşük kalite başta olmalı.
      final manifest = buildDashManifest(
        [
          stream(height: 1080, bitrate: 4000000, itag: 137),
          stream(height: 360, bitrate: 600000, itag: 134),
          stream(height: 720, bitrate: 2000000, itag: 136),
        ],
        durationSeconds: 100,
      )!;

      expect(manifest.indexOf('itag=134'), lessThan(manifest.indexOf('itag=136')));
      expect(manifest.indexOf('itag=136'), lessThan(manifest.indexOf('itag=137')));
    });

    test('adreslerdeki & işareti kaçırılır', () {
      // Kaçırılmazsa XML bozulur ve manifest hiç çözümlenemez.
      final manifest = buildDashManifest(
        [
          stream(
            height: 720,
            bitrate: 2000000,
            itag: 136,
            url: 'https://r1.test/videoplayback?itag=136&expire=1&sig=a"b',
          ),
          stream(height: 360, bitrate: 600000, itag: 134),
        ],
        durationSeconds: 100,
      )!;

      expect(manifest, contains('itag=136&amp;expire=1&amp;sig=a&quot;b'));
      expect(manifest.contains('sig=a"b'), isFalse);
    });

    test('parça baytları olmayan akış manifeste alınmaz', () {
      // YouTube bunları OTF akışlarda vermez; alınırsa oynatıcı o
      // çözünürlüğün parça dizinini bulamaz.
      final manifest = buildDashManifest(
        [
          stream(height: 1080, bitrate: 4000000, itag: 137),
          stream(height: 720, bitrate: 2000000, itag: 136),
          stream(
            height: 480,
            bitrate: 1000000,
            itag: 135,
            indexStart: -1,
            indexEnd: -1,
          ),
        ],
        durationSeconds: 100,
      )!;

      expect('<Representation '.allMatches(manifest).length, 2);
      expect(manifest.contains('itag=135'), isFalse);
    });

    test('farklı kodekler ayrı AdaptationSet\'e girer', () {
      // Kodekler arası geçiş her cihazda desteklenmiyor; oynatıcı bir aile
      // seçip yalnızca onun içinde çözünürlük değiştirmeli.
      final manifest = buildDashManifest(
        [
          stream(height: 1080, bitrate: 4000000, itag: 137),
          stream(height: 720, bitrate: 2000000, itag: 136),
          stream(
            height: 1080,
            bitrate: 3000000,
            itag: 248,
            codec: 'vp9',
            mimeType: 'video/webm',
          ),
          stream(
            height: 720,
            bitrate: 1500000,
            itag: 247,
            codec: 'vp9',
            mimeType: 'video/webm',
          ),
        ],
        durationSeconds: 100,
      )!;

      expect('<AdaptationSet '.allMatches(manifest).length, 2);
      expect(manifest, contains('mimeType="video/mp4"'));
      expect(manifest, contains('mimeType="video/webm"'));
    });

    test('tek kullanılabilir çözünürlük varsa manifest kurulmaz', () {
      // Uyarlanacak bir şey yok; manifestin ek yükünü taşımak yerine
      // çağıran taraf eski (progressive) yola düşmeli.
      expect(
        buildDashManifest(
          [stream(height: 720, bitrate: 2000000)],
          durationSeconds: 100,
        ),
        isNull,
      );
    });

    test('süresi bilinmeyen içerikte manifest kurulmaz', () {
      expect(
        buildDashManifest(
          [
            stream(height: 1080, bitrate: 4000000, itag: 137),
            stream(height: 720, bitrate: 2000000, itag: 136),
          ],
          durationSeconds: 0,
        ),
        isNull,
      );
    });

    test('kodeği bilinmeyen akışlar tek başına manifest kurduramaz', () {
      final incomplete = VideoStreamInfo(
        url: 'https://r1.test/videoplayback?itag=22',
        resolution: '720p',
        format: 'MPEG-4',
        isVideoOnly: false,
        fps: 30,
        bitrate: 2000000,
      );

      expect(
        buildDashManifest([incomplete, incomplete], durationSeconds: 100),
        isNull,
      );
    });
  });

  group('buildDashDataUri', () {
    VideoDetails details(List<VideoStreamInfo> streams, int duration) =>
        VideoDetails(
          videoId: 'abc123',
          title: 'Bir video',
          uploaderName: 'Kanal',
          uploaderUrl: null,
          durationSeconds: duration,
          viewCount: 0,
          description: '',
          category: null,
          tags: const [],
          isLive: false,
          thumbnailUrl: null,
          hlsUrl: null,
          dashMpdUrl: null,
          videoStreams: const [],
          videoOnlyStreams: streams,
          audioStreams: const [],
          relatedItems: const [],
        );

    test('manifest base64 adres olarak taşınır ve aynen geri çözülür', () {
      final streams = [
        stream(height: 1080, bitrate: 4000000, itag: 137),
        stream(height: 720, bitrate: 2000000, itag: 136),
      ];

      final uri = buildDashDataUri(details(streams, 212));

      expect(uri, isNotNull);
      expect(uri, startsWith(dashDataUriPrefix));
      // Satır sonu içeren bir base64 adresi bozardı.
      expect(uri!.contains('\n'), isFalse);
      expect(
        utf8.decode(base64Decode(uri.substring(dashDataUriPrefix.length))),
        buildDashManifest(streams, durationSeconds: 212),
      );
    });

    test('manifest kurulamıyorsa null döner', () {
      expect(buildDashDataUri(details(const [], 212)), isNull);
    });
  });
}
