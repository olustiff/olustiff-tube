import '../extraction/models.dart';

/// Bir videonun oynatılabilmesi için seçilen kaynak çifti.
///
/// [videoUrl] null ise oynatma sesli moddadır: video parçası hiç indirilmez.
class SelectedStreams {
  final String? videoUrl;
  final String audioUrl;
  final String? qualityLabel;

  /// true ise [audioUrl] bir HLS manifestidir ve native taraf tek kaynaktan
  /// oynatır; sesli mod, kaynak ayıklamayla değil parça devre dışı bırakmayla
  /// uygulanır.
  final bool isLive;

  const SelectedStreams({
    required this.videoUrl,
    required this.audioUrl,
    required this.qualityLabel,
    this.isLive = false,
  });
}

/// Varsayılan üst kalite sınırı.
///
/// YouTube sık sık 1440p/2160p sunar; telefon ekranında bu fark edilmezken
/// veri, pil ve donanım kod çözücüsünü gereksiz zorlar (bazı cihazlarda 4K
/// kod çözme hiç desteklenmez ve video siyah kalır). TV'de daha yükseğine
/// izin vermek için çağrı yerinde [maxHeight] geçilebilir.
const int defaultMaxHeight = 1080;

/// Çözünürlük etiketini ("1080p60", "720p") sıralanabilir bir sayıya çevirir.
int parseResolution(String? resolution) {
  if (resolution == null) return 0;
  final match = RegExp(r'(\d+)').firstMatch(resolution);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// En yüksek bit hızlı ses akışını seçer — sesli modun kalitesini belirler.
AudioStreamInfo? bestAudio(List<AudioStreamInfo> streams) {
  if (streams.isEmpty) return null;
  final sorted = [...streams]
    ..sort((a, b) => b.averageBitrate.compareTo(a.averageBitrate));
  return sorted.first;
}

/// Oynatma için video/ses kaynaklarını seçer.
///
/// [maxHeight] o çözünürlüğü aşmayan en iyi akışı seçtirir
/// (varsayılan [defaultMaxHeight]); `null` verilirse sınır uygulanmaz.
///
/// YouTube yüksek çözünürlükleri yalnızca "video-only" akış olarak sunar, bu
/// yüzden önce ayrık akışlar denenir (ses ayrı birleştirilir); ayrık ses yoksa
/// sesi de içeren birleşik akışa düşülür.
SelectedStreams? selectStreams(
  VideoDetails details, {
  required bool audioOnly,
  int? maxHeight = defaultMaxHeight,
}) {
  // Canlı yayınlar ayrık progressive akış sunmaz; tek yol HLS manifestidir.
  final hlsUrl = details.hlsUrl;
  if (details.isLive && hlsUrl != null && hlsUrl.isNotEmpty) {
    return SelectedStreams(
      videoUrl: null,
      audioUrl: hlsUrl,
      qualityLabel: audioOnly ? 'Canlı • sadece ses' : 'Canlı',
      isLive: true,
    );
  }

  final audio = bestAudio(details.audioStreams);

  if (audioOnly) {
    if (audio == null) return null;
    return SelectedStreams(
      videoUrl: null,
      audioUrl: audio.url,
      qualityLabel: 'Sadece ses',
    );
  }

  if (audio != null && details.videoOnlyStreams.isNotEmpty) {
    final candidates = [...details.videoOnlyStreams]
      ..sort((a, b) =>
          parseResolution(b.resolution).compareTo(parseResolution(a.resolution)));
    final chosen = maxHeight == null
        ? candidates.first
        : candidates.firstWhere(
            (s) => parseResolution(s.resolution) <= maxHeight,
            orElse: () => candidates.last,
          );
    return SelectedStreams(
      videoUrl: chosen.url,
      audioUrl: audio.url,
      qualityLabel: chosen.resolution,
    );
  }

  // Ayrık ses yoksa: sesi zaten içeren birleşik akışı tek kaynak olarak kullan.
  if (details.videoStreams.isNotEmpty) {
    final combined = [...details.videoStreams]
      ..sort((a, b) =>
          parseResolution(b.resolution).compareTo(parseResolution(a.resolution)));
    final chosen = maxHeight == null
        ? combined.first
        : combined.firstWhere(
            (s) => parseResolution(s.resolution) <= maxHeight,
            orElse: () => combined.last,
          );
    return SelectedStreams(
      videoUrl: null,
      audioUrl: chosen.url,
      qualityLabel: chosen.resolution,
    );
  }

  if (audio != null) {
    return SelectedStreams(
      videoUrl: null,
      audioUrl: audio.url,
      qualityLabel: 'Sadece ses',
    );
  }

  return null;
}
