import '../extraction/models.dart';

/// Bir dizi bölümünün ardından SIRADAKİ bölümü bulur.
///
/// Neden başlıktan çıkarım: NewPipeExtractor'ın `StreamInfo` nesnesi videonun
/// hangi oynatma listesine ait olduğunu taşımıyor (v0.26.5'te yalnızca
/// `relatedItems` var), yani "bu video şu listenin 3. sırası" bilgisi hiç
/// gelmiyor. Elimizdeki tek güvenilir sinyal başlığın kendisi.
///
/// Yanlış eşleşme burada pahalı: "Top 10 Şarkı - Bölüm 3" de bölüm kalıbına
/// uyuyor. Bu yüzden bir adayın "sıradaki bölüm" sayılması için AYNI kanal,
/// AYNI dizi gövdesi ve YAKIN süre şartlarının hepsi birden aranıyor.

/// Bir video başlığından okunan dizi/bölüm bilgisi.
class EpisodeRef {
  /// Dizi adının anlamlı kelimeleri. İki başlığın aynı diziye ait olup
  /// olmadığı bununla karşılaştırılır — ham başlık, yayın tarihinden
  /// "Full HD"ye kadar her şeyi taşıdığı için karşılaştırmaya elverişsiz.
  final Set<String> series;

  /// Başlıkta sezon yazmıyorsa null; Türkçe başlıkların çoğu yalnızca bölüm
  /// numarası veriyor ("Arka Sıradakiler 1. Bölüm").
  final int? season;

  final int episode;

  const EpisodeRef({
    required this.series,
    required this.season,
    required this.episode,
  });

  /// Sıralama anahtarı.
  ///
  /// Sezonu yazılmamış bölümler 1. sezon sayılır; böylece "45. Bölüm (Final)"
  /// ile "2. Sezon 1. Bölüm" aynı ölçekte karşılaştırılabiliyor ve sezon
  /// geçişi doğru yöne düşüyor.
  int get order => (season ?? 1) * 10000 + episode;
}

/// [episodeRunFor] sonucu: kuyruğun başına konacak bölümler ve kuyruğa hiç
/// girmemesi gereken videolar.
class EpisodeRun {
  /// Sıradaki bölümler, artan bölüm sırasında.
  final List<VideoSummary> upcoming;

  /// Kuyruktan tamamen çıkarılacak videolar: geride kalan bölümler ve aynı
  /// bölümün başka yüklemeleri. Kullanıcı 1. bölümü izlerken "Sırada"da
  /// 54. bölümü görmemeli.
  final Set<String> excludedIds;

  const EpisodeRun({required this.upcoming, required this.excludedIds});

  static const none =
      EpisodeRun(upcoming: <VideoSummary>[], excludedIds: <String>{});

  bool get isEmpty => upcoming.isEmpty;
}

/// [seed] bir dizi bölümüyse, aynı kanaldaki sıradaki bölümleri sırayla verir.
///
/// Dizi olduğu anlaşılamazsa ya da ileride bir bölüm bulunamazsa
/// [EpisodeRun.none] döner — çağıran taraf sessizce eski (benzerlik) sırasına
/// devam etsin diye.
EpisodeRun episodeRunFor({
  required VideoSummary seed,
  required Iterable<VideoSummary> candidates,
  Set<String> watchedIds = const {},
  int limit = 20,
}) {
  final seedRef = parseEpisode(seed.title);
  final seedChannel = _channelKey(seed.uploaderName);
  if (seedRef == null || seedChannel == null) return EpisodeRun.none;

  // Aynı diziye ait bulunan HER aday: seçilmeyenler kuyruktan çıkarılacak.
  final related = <String>{};
  // Bölüm sırası → o bölümün en iyi yüklemesi.
  final byOrder = <int, VideoSummary>{};
  final visited = <String>{};

  for (final candidate in candidates) {
    final id = candidate.videoId;
    if (id == null || id == seed.videoId || !visited.add(id)) continue;

    final ref = parseEpisode(candidate.title);
    if (ref == null || !_sameSeries(seedRef.series, ref.series)) continue;
    related.add(id);

    // Sıradaki bölüm olmanın şartları. Başka kanaldan gelen aynı dizi, çoğu
    // zaman aynı bölümün korsan/özet yüklemesi — sırayı ondan kurmak kuyruğu
    // aynı içeriğin kopyalarıyla doldururdu.
    if (_channelKey(candidate.uploaderName) != seedChannel) continue;
    if (ref.order <= seedRef.order) continue;
    if (!_durationFits(seed.durationSeconds, candidate.durationSeconds)) {
      continue;
    }

    final existing = byOrder[ref.order];
    if (existing == null || candidate.viewCount > existing.viewCount) {
      byOrder[ref.order] = candidate;
    }
  }

  if (byOrder.isEmpty) return EpisodeRun.none;

  final orders = byOrder.keys.toList()..sort();
  var upcoming = [for (final order in orders) byOrder[order]!];

  // İzlenmiş bölümleri atla: dizi yarıda bırakılmışsa kuyruk kalınan yerden
  // devam etmeli. Hepsi izlenmişse sırayı bozmaktansa baştan sırala.
  final unwatched =
      upcoming.where((v) => !watchedIds.contains(v.videoId)).toList();
  if (unwatched.isNotEmpty) upcoming = unwatched;

  if (upcoming.length > limit) upcoming = upcoming.sublist(0, limit);

  final chosen = {for (final v in upcoming) v.videoId};
  return EpisodeRun(
    upcoming: upcoming,
    excludedIds: related.where((id) => !chosen.contains(id)).toSet(),
  );
}

/// Başlıktan sezon/bölüm bilgisini okur; bölüm numarası yoksa null.
EpisodeRef? parseEpisode(String title) {
  final folded = foldTurkish(title);

  // Fragman, özet, jenerik: bölüm numarası taşırlar ama bölümün KENDİSİ
  // değildirler; kuyruğa girerlerse kullanıcı bölüm yerine reklam izler.
  if (_notAnEpisode.hasMatch(folded)) return null;

  int? season;
  int? episode;
  var markerStart = folded.length;
  var markerEnd = 0;

  void mark(Match match) {
    if (match.start < markerStart) markerStart = match.start;
    if (match.end > markerEnd) markerEnd = match.end;
  }

  final combined = _seasonEpisode.firstMatch(folded);
  if (combined != null) {
    season = int.tryParse(combined.group(1)!);
    episode = int.tryParse(combined.group(2)!);
    mark(combined);
  } else {
    final seasonMatch = _seasonBeforeWord.firstMatch(folded) ??
        _seasonAfterWord.firstMatch(folded);

    // Sezon bilgisi bölüm aramasından ÇIKARILIR: "Sezon 3 Bölüm 8"de sezonun
    // 3'ü "3 Bölüm" kalıbına da uyuyor ve bölüm numarasını 3 sanıyorduk.
    // Aynı uzunlukta boşlukla değiştirmek konumları bozmadan bunu engelliyor.
    var haystack = folded;
    if (seasonMatch != null) {
      season = int.tryParse(seasonMatch.group(1)!);
      mark(seasonMatch);
      haystack = folded.replaceRange(
        seasonMatch.start,
        seasonMatch.end,
        ' ' * (seasonMatch.end - seasonMatch.start),
      );
    }

    final episodeMatch = _episodeBeforeWord.firstMatch(haystack) ??
        _episodeAfterWord.firstMatch(haystack) ??
        _episodeEnglish.firstMatch(haystack);
    if (episodeMatch == null) return null;
    episode = int.tryParse(episodeMatch.group(1)!);
    mark(episodeMatch);
  }

  if (episode == null || episode <= 0) return null;
  // Dört haneli sayılar neredeyse her zaman yıldır ("2024 Bölüm"); en uzun
  // Türk dizileri bile bu sınırın altında kalıyor.
  if (episode > _maxEpisodeNumber) return null;
  if (season != null && (season <= 0 || season > 99)) season = null;

  final series = _seriesTokens(folded, markerStart, markerEnd);
  if (series.isEmpty) return null;

  return EpisodeRef(series: series, season: season, episode: episode);
}

/// Türkçe harfleri ASCII karşılığına indirger ve küçültür.
///
/// Aynı dizi "Kuruluş Osman", "KURULUŞ OSMAN" ve "Kurulus Osman" diye
/// yazılabiliyor; ayrıca Dart'ın `toLowerCase`'i 'İ' için birleşen nokta
/// üretip karşılaştırmayı bozuyor.
String foldTurkish(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_asciiFolds[char] ?? char.toLowerCase());
  }
  return buffer.toString();
}

const _maxEpisodeNumber = 1500;

const _asciiFolds = <String, String>{
  'ç': 'c', 'Ç': 'c',
  'ğ': 'g', 'Ğ': 'g',
  'ı': 'i', 'I': 'i', 'İ': 'i',
  'ö': 'o', 'Ö': 'o',
  'ş': 's', 'Ş': 's',
  'ü': 'u', 'Ü': 'u',
  'â': 'a', 'Â': 'a',
  'î': 'i', 'Î': 'i',
  'û': 'u', 'Û': 'u',
  'é': 'e', 'É': 'e',
};

/// "S02E05", "s2 e5", "S02:E05"
final _seasonEpisode = RegExp(r'\bs\s*(\d{1,2})\s*[:\-]?\s*e\s*(\d{1,4})\b');

/// "2. Sezon", "2.Sezon", "2 Sezon"
final _seasonBeforeWord = RegExp(r'(\d{1,2})\s*\.?\s*sezon');

/// "Sezon 2", "Sezon: 2"
final _seasonAfterWord = RegExp(r'\bsezon\w*\s*[:.\-]?\s*(\d{1,2})\b');

/// "45. Bölüm", "45.Bölüm", "45 Bölüm"
final _episodeBeforeWord = RegExp(r'(\d{1,4})\s*\.?\s*bolum');

/// "Bölüm 12", "Bölüm: 12"
final _episodeAfterWord = RegExp(r'\bbolum\w*\s*[:.\-]?\s*(\d{1,4})\b');

/// "Episode 5", "Ep. 5"
final _episodeEnglish = RegExp(r'\bep(?:isode)?\s*[:.\-]?\s*(\d{1,4})\b');

/// Bölüm numarası taşıyan ama bölüm OLMAYAN içerikler.
final _notAnEpisode = RegExp(
  r'\b(fragman\w*|teaser\w*|tanitim\w*|ozet\w*|jenerik\w*|sahneler\w*'
  r'|reaction|tepki|analiz\w*|klip|kamera arkasi)\b',
);

final _tokenSplit = RegExp(r'[^a-z0-9]+');

/// Sayı ya da "1080p" gibi teknik jetonlar dizi adını ayırt etmez.
final _numericToken = RegExp(r'^\d+[a-z]?$');

/// Dizi adının parçası sayılmayacak, hemen her başlıkta geçen kelimeler.
const _titleNoise = <String>{
  'full', 'hd', 'fhd', 'uhd', 'sd',
  'izle', 'izleyin', 'tek', 'parca', 'final', 'finali',
  'sezon', 'sezonu', 'sezonun', 'bolum', 'bolumu', 'bolumun', 'bolumleri',
  'yeni', 'son', 'official', 'resmi', 'dizi', 'dizisi', 'dizisinin',
  'altyazili', 'kesintisiz', 'reklamsiz', 'episode', 'season', 'part',
  'the', 'and', 'ile',
};

/// Dizi adı, bölüm işaretinin ÖNÜNDE aranır: Türkçe başlıklarda ad hep başta
/// ("Arka Sıradakiler 1. Bölüm"), işaretten sonrası ise bölüm başlığı ve
/// pazarlama metni oluyor. Ad öne yazılmamışsa ("S02E05 Kuruluş Osman")
/// işaretin arkası kullanılır.
Set<String> _seriesTokens(String folded, int markerStart, int markerEnd) {
  final before = _tokens(folded.substring(0, markerStart));
  if (before.isNotEmpty) return before;
  return _tokens(folded.substring(markerEnd));
}

Set<String> _tokens(String folded) => folded
    .split(_tokenSplit)
    .where((token) =>
        token.length >= 2 &&
        !_titleNoise.contains(token) &&
        !_numericToken.hasMatch(token))
    .toSet();

/// İki başlık aynı diziye mi ait?
///
/// Sadece ortak kelime aramak yetmiyor: "Arka Sokaklar" ile "Arka
/// Sıradakiler" aynı kanalda yan yana durabiliyor. Küçük kümenin büyük ölçüde
/// kapsanması şartı bu tür yakın adları ayırıyor.
bool _sameSeries(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return false;
  final common = a.intersection(b);
  if (common.isEmpty) return false;
  final smaller = a.length < b.length ? a.length : b.length;
  if (common.length / smaller < 0.6) return false;
  // Tek harflik/çok kısa ortaklık ("bb", "tv") dizi kimliği taşımaz.
  return common.any((token) => token.length >= 3);
}

String? _channelKey(String? uploaderName) {
  final trimmed = uploaderName?.trim().toLowerCase();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// Aynı dizinin bölümleri kabaca aynı uzunlukta olur. Bu şart, bölüm
/// numarası taşıyan kısa tanıtım videolarını da eliyor.
bool _durationFits(int seedSeconds, int candidateSeconds) {
  if (seedSeconds <= 0 || candidateSeconds <= 0) return true;
  final ratio = candidateSeconds > seedSeconds
      ? candidateSeconds / seedSeconds
      : seedSeconds / candidateSeconds;
  return ratio <= 2.5;
}
