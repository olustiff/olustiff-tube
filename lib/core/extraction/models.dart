// Native (Kotlin/NewPipeExtractor) taraftan gelen ham `Map` verilerini
// tip güvenli Dart nesnelerine çeviren modeller.

int _asInt(dynamic value) => value == null ? 0 : (value as num).toInt();

String? _asString(dynamic value) => value as String?;

/// Arama sonucu / trend / ilgili video listelerinde kullanılan özet kart verisi.
class VideoSummary {
  final String? videoId;
  final String title;
  final String? url;
  final String? uploaderName;
  final int durationSeconds;
  final int viewCount;
  final String? textualUploadDate;
  final String? thumbnailUrl;

  const VideoSummary({
    required this.videoId,
    required this.title,
    required this.url,
    required this.uploaderName,
    required this.durationSeconds,
    required this.viewCount,
    required this.textualUploadDate,
    required this.thumbnailUrl,
  });

  factory VideoSummary.fromMap(Map<Object?, Object?> map) {
    return VideoSummary(
      videoId: _asString(map['videoId']),
      title: _asString(map['title']) ?? '',
      url: _asString(map['url']),
      uploaderName: _asString(map['uploaderName']),
      durationSeconds: _asInt(map['durationSeconds']),
      viewCount: _asInt(map['viewCount']),
      textualUploadDate: _asString(map['textualUploadDate']),
      thumbnailUrl: _asString(map['thumbnailUrl']),
    );
  }
}

/// Oynatılabilir bir video (veya video-only) DASH/progressive stream'i.
class VideoStreamInfo {
  final String url;
  final String? resolution;
  final String? format;
  final bool isVideoOnly;
  final int fps;
  final int bitrate;

  const VideoStreamInfo({
    required this.url,
    required this.resolution,
    required this.format,
    required this.isVideoOnly,
    required this.fps,
    required this.bitrate,
  });

  factory VideoStreamInfo.fromMap(Map<Object?, Object?> map) {
    return VideoStreamInfo(
      url: _asString(map['url']) ?? '',
      resolution: _asString(map['resolution']),
      format: _asString(map['format']),
      isVideoOnly: map['isVideoOnly'] as bool? ?? false,
      fps: _asInt(map['fps']),
      bitrate: _asInt(map['bitrate']),
    );
  }
}

/// Ses-yalnız DASH stream'i (yüksek çözünürlüklü videolar genelde
/// video+audio ayrı gelir, oynatıcı bunları birleştirir — bkz. Faz 2).
class AudioStreamInfo {
  final String url;
  final String? format;
  final int averageBitrate;

  const AudioStreamInfo({
    required this.url,
    required this.format,
    required this.averageBitrate,
  });

  factory AudioStreamInfo.fromMap(Map<Object?, Object?> map) {
    return AudioStreamInfo(
      url: _asString(map['url']) ?? '',
      format: _asString(map['format']),
      averageBitrate: _asInt(map['averageBitrate']),
    );
  }
}

/// Bir videonun oynatma sayfası için gereken her şey: başlık, açıklama,
/// tüm stream seçenekleri ve ilgili videolar.
class VideoDetails {
  final String videoId;
  final String title;
  final String? uploaderName;
  final String? uploaderUrl;
  final int durationSeconds;
  final int viewCount;
  final String description;
  final String? thumbnailUrl;
  final String? hlsUrl;
  final String? dashMpdUrl;
  final List<VideoStreamInfo> videoStreams;
  final List<VideoStreamInfo> videoOnlyStreams;
  final List<AudioStreamInfo> audioStreams;
  final List<VideoSummary> relatedItems;

  const VideoDetails({
    required this.videoId,
    required this.title,
    required this.uploaderName,
    required this.uploaderUrl,
    required this.durationSeconds,
    required this.viewCount,
    required this.description,
    required this.thumbnailUrl,
    required this.hlsUrl,
    required this.dashMpdUrl,
    required this.videoStreams,
    required this.videoOnlyStreams,
    required this.audioStreams,
    required this.relatedItems,
  });

  factory VideoDetails.fromMap(Map<Object?, Object?> map) {
    List<T> mapList<T>(Object? raw, T Function(Map<Object?, Object?>) convert) {
      final list = raw as List<Object?>? ?? const [];
      return list
          .map((e) => convert(e as Map<Object?, Object?>))
          .toList(growable: false);
    }

    return VideoDetails(
      videoId: _asString(map['videoId']) ?? '',
      title: _asString(map['title']) ?? '',
      uploaderName: _asString(map['uploaderName']),
      uploaderUrl: _asString(map['uploaderUrl']),
      durationSeconds: _asInt(map['durationSeconds']),
      viewCount: _asInt(map['viewCount']),
      description: _asString(map['description']) ?? '',
      thumbnailUrl: _asString(map['thumbnailUrl']),
      hlsUrl: _asString(map['hlsUrl']),
      dashMpdUrl: _asString(map['dashMpdUrl']),
      videoStreams: mapList(map['videoStreams'], VideoStreamInfo.fromMap),
      videoOnlyStreams:
          mapList(map['videoOnlyStreams'], VideoStreamInfo.fromMap),
      audioStreams: mapList(map['audioStreams'], AudioStreamInfo.fromMap),
      relatedItems: mapList(map['relatedItems'], VideoSummary.fromMap),
    );
  }
}
