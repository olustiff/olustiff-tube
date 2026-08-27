import 'dart:convert';

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

/// "Otomatik" kurulamadığında düşülen üst kalite sınırı.
///
/// YouTube sık sık 1440p/2160p sunar; telefon ekranında bu fark edilmezken
/// veri, pil ve donanım kod çözücüsünü gereksiz zorlar (bazı cihazlarda 4K
/// kod çözme hiç desteklenmez ve video siyah kalır).
const int defaultMaxHeight = 1080;

/// Kalite menüsünde ve oynatma ekranında gösterilen "Otomatik" etiketi.
const String autoQualityLabel = 'Otomatik';

/// Uyarlanabilir manifestin taşındığı adres öneki.
///
/// Oynatma isteği native tarafa yalnızca "video adresi + ses adresi" olarak
/// geçiyor; manifesti ayrı bir alan eklemek yerine adresin kendisine gömmek
/// mevcut yolu hiç değiştirmeden çalışıyor. Native taraf bu öneki görünce
/// içeriği çözüp DASH kaynağı kuruyor.
const String dashDataUriPrefix = 'data:application/dash+xml;base64,';

/// Videonun gerçekten sunduğu çözünürlükler (yüksekten alçağa).
///
/// Kalite menüsü bundan üretilir; sabit bir liste kullanmak videoda olmayan
/// seçenekleri (ör. 4K sunmayan bir videoda "2160p") göstermeye yol açar.
List<int> availableHeights(VideoDetails details) {
  final heights = <int>{};
  for (final stream in [...details.videoOnlyStreams, ...details.videoStreams]) {
    final height = parseResolution(stream.resolution);
    if (height > 0) heights.add(height);
  }
  final sorted = heights.toList()..sort((a, b) => b.compareTo(a));
  return sorted;
}

/// Çözünürlük etiketini ("1080p60", "720p") sıralanabilir bir sayıya çevirir.
int parseResolution(String? resolution) {
  if (resolution == null) return 0;
  final match = RegExp(r'(\d+)').firstMatch(resolution);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// Videonun tüm çözünürlüklerini tek bir DASH manifestine toplar.
///
/// Neden gerekli: YouTube normal videolar için hazır bir DASH manifesti
/// VERMEZ; her çözünürlük ayrı bir progressive adres olarak gelir. Oynatıcıya
/// bunlardan yalnızca birini verdiğimizde ağ yavaşladığında düşecek bir kalite
/// kalmıyor ve video takılıyor. Hepsini tek manifestte toplamak oynatıcıya
/// indirme hızına göre çözünürlükler arasında geçiş yapma imkânı veriyor.
///
/// Kurulamıyorsa null döner — çağıran taraf sabit çözünürlüğe düşmeli.
String? buildDashManifest(
  List<VideoStreamInfo> streams, {
  required int durationSeconds,
}) {
  if (durationSeconds <= 0) return null;

  final usable = streams.where(_isDashUsable).toList();
  // Tek temsilci varsa uyarlanacak bir şey yok; manifestin ek yükünü taşımak
  // yerine eski (progressive) yola düşmek daha doğru.
  if (usable.length < 2) return null;

  // Kodekler arası geçiş her cihazda desteklenmediği için her kodek ailesi
  // kendi AdaptationSet'ine giriyor; oynatıcı bir aile seçip yalnızca onun
  // içinde çözünürlük değiştiriyor.
  final groups = <String, List<VideoStreamInfo>>{};
  for (final stream in usable) {
    final family = stream.codec!.split('.').first;
    groups.putIfAbsent('${stream.mimeType}|$family', () => []).add(stream);
  }
  final adaptationSets = groups.values.where((g) => g.length >= 2).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (adaptationSets.isEmpty) return null;

  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>')
    ..write('<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" ')
    ..write('profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" ')
    ..write('type="static" minBufferTime="PT1.5S" ')
    ..write('mediaPresentationDuration="PT${durationSeconds}S">')
    ..write('<Period duration="PT${durationSeconds}S">');

  for (var i = 0; i < adaptationSets.length; i++) {
    final group = [...adaptationSets[i]]
      // Düşükten yükseğe: oynatıcı ilk parçayı en düşükten çekip ölçümüne
      // göre yükseliyor, böylece açılış takılmıyor.
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    buffer
      ..write('<AdaptationSet id="$i" mimeType="${group.first.mimeType}" ')
      ..write('contentType="video" subsegmentAlignment="true" ')
      ..write('startWithSAP="1">');
    for (final stream in group) {
      buffer
        ..write('<Representation id="${stream.itag}" ')
        ..write('codecs="${_escapeXml(stream.codec!)}" ')
        ..write('bandwidth="${stream.bitrate}" ')
        ..write('width="${stream.width}" height="${stream.height}"');
      if (stream.fps > 0) buffer.write(' frameRate="${stream.fps}"');
      buffer
        ..write('>')
        ..write('<BaseURL>${_escapeXml(stream.url)}</BaseURL>')
        ..write('<SegmentBase indexRange="'
            '${stream.indexStart}-${stream.indexEnd}">')
        ..write('<Initialization range="'
            '${stream.initStart}-${stream.initEnd}"/>')
        ..write('</SegmentBase>')
        ..write('</Representation>');
    }
    buffer.write('</AdaptationSet>');
  }

  buffer.write('</Period></MPD>');
  return buffer.toString();
}

/// [buildDashManifest] çıktısını oynatıcıya verilebilir bir adrese çevirir.
String? buildDashDataUri(VideoDetails details) {
  final manifest = buildDashManifest(
    details.videoOnlyStreams,
    durationSeconds: details.durationSeconds,
  );
  if (manifest == null) return null;
  return '$dashDataUriPrefix${base64Encode(utf8.encode(manifest))}';
}

/// Parça baytları (init/index aralıkları) olmayan akış manifeste giremez:
/// oynatıcı o akışın parça dizinini bulamaz. YouTube bunları OTF akışlarda
/// vermez, orada -1 gelir.
bool _isDashUsable(VideoStreamInfo stream) =>
    stream.url.isNotEmpty &&
    (stream.codec?.isNotEmpty ?? false) &&
    (stream.mimeType?.isNotEmpty ?? false) &&
    stream.initStart >= 0 &&
    stream.initEnd > 0 &&
    stream.indexStart >= 0 &&
    stream.indexEnd > 0 &&
    stream.bitrate > 0 &&
    stream.width > 0 &&
    stream.height > 0;

/// YouTube adresleri `&` içeriyor; kaçırılmazsa XML bozulur.
String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// En yüksek bit hızlı ses akışını seçer — sesli modun kalitesini belirler.
AudioStreamInfo? bestAudio(List<AudioStreamInfo> streams) {
  if (streams.isEmpty) return null;
  final sorted = [...streams]
    ..sort((a, b) => b.averageBitrate.compareTo(a.averageBitrate));
  return sorted.first;
}

/// Oynatma için video/ses kaynaklarını seçer.
///
/// [maxHeight] o çözünürlüğü aşmayan en iyi akışı seçtirir. `null` verilirse
/// kalite OTOMATİKTİR: tüm çözünürlükler tek bir DASH manifestine konur ve
/// hangisinin oynatılacağına oynatıcı bant genişliğine bakarak karar verir.
/// Manifest kurulamıyorsa (bkz. [buildDashManifest]) kullanıcıya hata
/// göstermek yerine sessizce [defaultMaxHeight] sınırına düşülür.
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

  // Kullanıcı bir çözünürlük sabitlemediyse ("Otomatik") kararı oynatıcıya
  // bırakıyoruz.
  final ceiling = maxHeight ?? defaultMaxHeight;

  if (audio != null && details.videoOnlyStreams.isNotEmpty) {
    if (maxHeight == null) {
      final manifest = buildDashDataUri(details);
      if (manifest != null) {
        return SelectedStreams(
          videoUrl: manifest,
          audioUrl: audio.url,
          qualityLabel: autoQualityLabel,
        );
      }
    }

    final candidates = [...details.videoOnlyStreams]
      ..sort((a, b) =>
          parseResolution(b.resolution).compareTo(parseResolution(a.resolution)));
    final chosen = candidates.firstWhere(
      (s) => parseResolution(s.resolution) <= ceiling,
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
    final chosen = combined.firstWhere(
      (s) => parseResolution(s.resolution) <= ceiling,
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
