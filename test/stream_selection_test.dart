import 'package:flutter_test/flutter_test.dart';

import 'package:akis/core/extraction/models.dart';
import 'package:akis/core/playback/content_kind.dart';
import 'package:akis/core/playback/stream_selection.dart';

VideoDetails buildDetails({
  String title = 'Bir video',
  String? category,
  List<String> tags = const [],
  bool isLive = false,
  String? hlsUrl,
  List<VideoStreamInfo> videoStreams = const [],
  List<VideoStreamInfo> videoOnlyStreams = const [],
  List<AudioStreamInfo> audioStreams = const [],
}) {
  return VideoDetails(
    videoId: 'abc123',
    title: title,
    uploaderName: 'Kanal',
    uploaderUrl: null,
    durationSeconds: 100,
    viewCount: 0,
    description: '',
    category: category,
    tags: tags,
    isLive: isLive,
    thumbnailUrl: null,
    hlsUrl: hlsUrl,
    dashMpdUrl: null,
    videoStreams: videoStreams,
    videoOnlyStreams: videoOnlyStreams,
    audioStreams: audioStreams,
    relatedItems: const [],
  );
}

VideoStreamInfo video(String resolution, {bool videoOnly = true}) =>
    VideoStreamInfo(
      url: 'https://example.test/video-$resolution',
      resolution: resolution,
      format: 'MPEG-4',
      isVideoOnly: videoOnly,
      fps: 30,
      bitrate: 1000,
    );

AudioStreamInfo audio(int bitrate) => AudioStreamInfo(
      url: 'https://example.test/audio-$bitrate',
      format: 'M4A',
      averageBitrate: bitrate,
    );

void main() {
  group('selectStreams', () {
    test('sesli modda video kaynağı hiç seçilmez', () {
      final details = buildDetails(
        videoOnlyStreams: [video('1080p60'), video('720p')],
        audioStreams: [audio(128), audio(160)],
      );

      final selected = selectStreams(details, audioOnly: true);

      expect(selected, isNotNull);
      expect(selected!.videoUrl, isNull,
          reason: 'sesli modda video parçası indirilmemeli');
      expect(selected.audioUrl, contains('audio-160'),
          reason: 'en yüksek bit hızlı ses seçilmeli');
    });

    test('video modunda en yüksek çözünürlük ve ayrı ses birleştirilir', () {
      final details = buildDetails(
        videoOnlyStreams: [video('720p'), video('1080p60'), video('480p')],
        audioStreams: [audio(160)],
      );

      final selected = selectStreams(details, audioOnly: false);

      expect(selected!.videoUrl, contains('video-1080p60'));
      expect(selected.audioUrl, contains('audio-160'));
      expect(selected.qualityLabel, '1080p60');
    });

    test('varsayılan olarak 4K yerine 1080p seçilir', () {
      final details = buildDetails(
        videoOnlyStreams: [video('2160p'), video('1440p'), video('1080p60')],
        audioStreams: [audio(160)],
      );

      final selected = selectStreams(details, audioOnly: false);

      expect(selected!.qualityLabel, '1080p60',
          reason: 'telefonda 4K gereksiz; bazı cihazlarda decode edilemez');
    });

    test('maxHeight null verilirse sınır uygulanmaz', () {
      final details = buildDetails(
        videoOnlyStreams: [video('2160p'), video('1080p60')],
        audioStreams: [audio(160)],
      );

      final selected =
          selectStreams(details, audioOnly: false, maxHeight: null);

      expect(selected!.qualityLabel, '2160p');
    });

    test('maxHeight sınırı aşılmaz', () {
      final details = buildDetails(
        videoOnlyStreams: [video('1080p60'), video('720p'), video('480p')],
        audioStreams: [audio(160)],
      );

      final selected =
          selectStreams(details, audioOnly: false, maxHeight: 720);

      expect(selected!.qualityLabel, '720p');
    });

    test('ayrık ses yoksa birleşik akış tek kaynak olarak kullanılır', () {
      final details = buildDetails(
        videoStreams: [video('360p', videoOnly: false)],
      );

      final selected = selectStreams(details, audioOnly: false);

      expect(selected!.videoUrl, isNull,
          reason: 'birleşik akışta ses zaten içeride, ayrıca merge edilmemeli');
      expect(selected.audioUrl, contains('video-360p'));
    });

    test('canlı yayında HLS manifesti kullanılır', () {
      final details = buildDetails(
        isLive: true,
        hlsUrl: 'https://example.test/live.m3u8',
        // Canlı yayınlarda bunlar genelde boş gelir, dolu olsa bile
        // HLS tercih edilmelidir.
        audioStreams: [audio(160)],
      );

      final videoMode = selectStreams(details, audioOnly: false);
      expect(videoMode!.isLive, isTrue);
      expect(videoMode.audioUrl, endsWith('.m3u8'));
      expect(videoMode.videoUrl, isNull,
          reason: 'HLS tek kaynaktır, ayrıca merge edilmemeli');

      final audioMode = selectStreams(details, audioOnly: true);
      expect(audioMode!.isLive, isTrue);
      expect(audioMode.audioUrl, endsWith('.m3u8'));
    });

    test('hiç kaynak yoksa null döner', () {
      expect(selectStreams(buildDetails(), audioOnly: false), isNull);
    });
  });

  group('availableHeights', () {
    test('yalnızca videonun sunduğu çözünürlükler listelenir', () {
      // 4K sunmayan bir videoda kalite menüsünde 2160p çıkmamalı.
      final details = buildDetails(
        videoOnlyStreams: [video('1080p60'), video('720p')],
        videoStreams: [video('360p', videoOnly: false)],
        audioStreams: [audio(160)],
      );

      expect(availableHeights(details), [1080, 720, 360]);
    });

    test('aynı çözünürlüğün farklı formatları tekrarlanmaz', () {
      final details = buildDetails(
        videoOnlyStreams: [video('1080p60'), video('1080p'), video('720p')],
      );

      expect(availableHeights(details), [1080, 720]);
    });

    test('kaynak yoksa liste boştur', () {
      expect(availableHeights(buildDetails()), isEmpty);
    });
  });

  group('detectContentKind', () {
    test('Music kategorisi sesli mod olarak tespit edilir', () {
      final details = buildDetails(category: 'Music');
      expect(detectContentKind(details), ContentKind.music);
    });

    test('diğer kategoriler video olarak tespit edilir', () {
      final details = buildDetails(category: 'Gaming', title: 'lofi mix');
      expect(detectContentKind(details), ContentKind.video,
          reason: 'açık kategori, başlık tahmininden öncelikli olmalı');
    });

    test('kategori yoksa başlıktan çıkarım yapılır', () {
      expect(
        detectContentKind(buildDetails(title: 'Bir şarkı - Official Audio')),
        ContentKind.music,
      );
      expect(
        detectContentKind(buildDetails(title: 'Flutter dersleri bölüm 3')),
        ContentKind.video,
      );
    });
  });
}
