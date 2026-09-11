import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/core/playback/content_kind.dart';
import 'package:olustiff/core/playback/stream_selection.dart';

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

/// DASH manifestine girebilecek bir akış: kodek, boyut ve parça baytları dolu.
///
/// [video] bilerek eksik bırakılıyor — YouTube bu bilgileri her akış için
/// vermez ve "Otomatik"in ona düştüğü davranış da sınanmalı.
VideoStreamInfo dashVideo(
  String resolution, {
  int height = 0,
  int bitrate = 1000000,
  String codec = 'avc1.640028',
  String mimeType = 'video/mp4',
  String? url,
  int itag = 137,
}) {
  final parsed = height > 0 ? height : parseResolution(resolution);
  return VideoStreamInfo(
    url: url ?? 'https://example.test/video-$resolution',
    resolution: resolution,
    format: 'MPEG-4',
    isVideoOnly: true,
    fps: 30,
    bitrate: bitrate,
    mimeType: mimeType,
    codec: codec,
    itag: itag,
    width: (parsed * 16 / 9).round(),
    height: parsed,
    initStart: 0,
    initEnd: 739,
    indexStart: 740,
    indexEnd: 1231,
  );
}

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

    test('otomatikte tüm çözünürlükler tek manifeste konur', () {
      final details = buildDetails(
        videoOnlyStreams: [
          dashVideo('2160p', itag: 401, bitrate: 14000000),
          dashVideo('1080p60', itag: 137, bitrate: 4000000),
          dashVideo('480p', itag: 135, bitrate: 1000000),
        ],
        audioStreams: [audio(160)],
      );

      final selected =
          selectStreams(details, audioOnly: false, maxHeight: null);

      expect(selected!.qualityLabel, 'Otomatik');
      expect(selected.videoUrl, startsWith(dashDataUriPrefix),
          reason: 'çözünürlüğü oynatıcı seçebilsin diye manifest verilmeli');
      expect(selected.audioUrl, contains('audio-160'),
          reason: 'ses ayrı akıştan gelmeye devam etmeli');

      final manifest = utf8.decode(
        base64Decode(selected.videoUrl!.substring(dashDataUriPrefix.length)),
      );
      expect(manifest, contains('video-2160p'));
      expect(manifest, contains('video-1080p60'));
      expect(manifest, contains('video-480p'));
    });

    test('manifest kurulamıyorsa otomatik sessizce 1080p sınırına düşer', () {
      // Parça baytları olmayan akışlar (OTF) manifeste giremez; kullanıcı
      // hata değil, oynayan bir video görmeli.
      final details = buildDetails(
        videoOnlyStreams: [video('2160p'), video('1080p60'), video('720p')],
        audioStreams: [audio(160)],
      );

      final selected =
          selectStreams(details, audioOnly: false, maxHeight: null);

      expect(selected!.videoUrl, contains('video-1080p60'));
      expect(selected.qualityLabel, '1080p60');
    });

    test('elle çözünürlük seçilirse manifest kullanılmaz', () {
      final details = buildDetails(
        videoOnlyStreams: [dashVideo('1080p60'), dashVideo('720p')],
        audioStreams: [audio(160)],
      );

      final selected =
          selectStreams(details, audioOnly: false, maxHeight: 720);

      expect(selected!.videoUrl, contains('video-720p'));
      expect(selected.qualityLabel, '720p');
    });

    test('sesli modda otomatik olsa bile manifest kurulmaz', () {
      final details = buildDetails(
        videoOnlyStreams: [dashVideo('1080p60'), dashVideo('720p')],
        audioStreams: [audio(160)],
      );

      final selected = selectStreams(details, audioOnly: true, maxHeight: null);

      expect(selected!.videoUrl, isNull);
      expect(selected.audioUrl, contains('audio-160'));
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

    // Gerçek kullanımda yakalandı: hayran derlemeleri "Entertainment" ya da
    // "People & Blogs" kategorisiyle yükleniyor ve kategoriye takılıp
    // başlığa bakmamak müzik dinleyene video indirtiyordu.
    test('güçlü ipucu, müzik dışı kategoriyi ezer', () {
      expect(
        detectContentKind(
          buildDetails(category: 'Entertainment', title: 'Sezen Aksu - Ey Aşk [Official Audio]'),
        ),
        ContentKind.music,
      );
      expect(
        detectContentKind(
          buildDetails(category: 'People & Blogs', title: 'RAIKAHO - ВСЕ ТРЕКИ'),
        ),
        ContentKind.music,
      );
      expect(
        detectContentKind(
          buildDetails(category: 'Entertainment', title: 'Janaga - лучшие песни'),
        ),
        ContentKind.music,
      );
    });

    // Zayıf ipuçları kategoriyi EZMEMELİ: "mix" bir oyun videosunun
    // başlığında da geçiyor.
    test('zayıf ipucu, açık kategoriyi ezmez', () {
      expect(
        detectContentKind(buildDetails(category: 'Gaming', title: 'my best mix')),
        ContentKind.video,
      );
      expect(
        detectContentKind(buildDetails(title: 'lofi mix')),
        ContentKind.music,
        reason: 'kategori yokken zayıf ipucu yine geçerli',
      );
    });

    test('etiketlerdeki ipucu da sayılır', () {
      expect(
        detectContentKind(
          buildDetails(category: 'Entertainment', tags: ['музыка', 'клип']),
        ),
        ContentKind.music,
      );
    });
  });
}
