import '../data/library_store.dart';
import '../extraction/models.dart';
import 'episode.dart';
import 'similarity.dart';

/// Oynatma kuyruğunu, "radyo" hissi verecek şekilde kurar.
///
/// İki şeyi birden dengeler:
/// - **Benzerlik**: kuyruk aynı dilde ve yakın tarzda kalmalı. Alakasız
///   içerik (başka bir dilde şarkı, saatlik bir mix) araya girerse kullanıcı
///   sıkılır.
/// - **Çeşitlilik**: aynı sanatçının şarkıları arka arkaya yığılmamalı —
///   "Selena Gomez" arayınca kuyruk baştan sona Selena Gomez olmamalı.
///
/// Dizi izlenirken bu denge YANLIŞ soruyu cevaplıyor: "1. Bölüm"den sonra en
/// benzer video "54. Bölüm" olabiliyor. Bölüm sırası anlaşılabiliyorsa
/// (bkz. [episodeRunFor]) kuyruğun başı benzerliğe değil bölüm numarasına
/// göre kurulur; anlaşılamazsa hiçbir şey değişmez.
class QueueBuilder {
  /// Aynı kanaldan üst üste kaç video çalabileceği.
  ///
  /// 2: aynı sanatçıdan iki şarkı peş peşe gelebilir (tarz bütünlüğü), ama
  /// üçüncüsü için araya başka biri girer. 1 yapmak, en benzer adayı her
  /// seferinde atlatıp kuyruğu gereksiz dağıtıyordu.
  static const _maxConsecutiveSameChannel = 2;

  /// Kuyruğun üst sınırı; çok uzun kuyruk hem gereksiz hem yönetilemez.
  static const _maxQueueLength = 50;

  /// Bu eşiğin altındaki adaylar kuyruğa hiç alınmaz.
  ///
  /// Yabancı yazı sistemi (-8) ve aşırı süre farkı (-6) tek başlarına aynı
  /// dil bonusunu (+4) götürdüğü için bu içerikler eşiği geçemez.
  static const _minScore = 0;

  /// Kuyruğun başına en fazla kaç bölüm konacağı. Kalan yerler yine benzer
  /// içerikle dolar; dizi bitince kuyruk boşalmasın.
  static const _maxEpisodeRun = 20;

  /// [seed] çalınan video, [candidates] aday havuzu (arama sonuçları ve/veya
  /// ilgili videolar). Sonuç, [seed] ile başlayan benzer ama tekdüze olmayan
  /// bir sıradır.
  ///
  /// [watchedIds] verilmezse izleme geçmişi [LibraryStore]'dan okunur;
  /// parametre yalnızca testlerin geçmişi kendilerinin belirlemesi için var.
  static List<VideoSummary> build({
    required VideoSummary seed,
    required List<VideoSummary> candidates,
    Set<String>? watchedIds,
  }) {
    final seen = <String>{if (seed.videoId != null) seed.videoId!};

    // Dizi izleniyorsa sıradaki bölümler kuyruğun BAŞINA gelir; aynı dizinin
    // seçilmeyen bölümleri (geride kalanlar, aynı bölümün başka yüklemeleri)
    // ise hiç girmesin diye görülmüş sayılır.
    final run = episodeRunFor(
      seed: seed,
      candidates: candidates,
      watchedIds: watchedIds ?? _watchedVideoIds(),
      limit: _maxEpisodeRun,
    );
    final episodes = <VideoSummary>[];
    for (final episode in run.upcoming) {
      final id = episode.videoId;
      if (id == null || !seen.add(id)) continue;
      episodes.add(episode);
    }
    seen.addAll(run.excludedIds);

    // Adayları benzerliğe göre puanla ve eşiği geçemeyenleri ele.
    //
    // AYNI PARÇANIN başka sürümleri baştan eleniyor. Yalnızca puana bakmak
    // ters sonuç veriyordu: bir şarkının remiksi o şarkıya en çok benzeyen
    // şey olduğu için kuyruğun başına geçiyor ve kuyruk baştan sona aynı
    // şarkının remiks/hızlandırılmış/kapak sürümleriyle doluyordu.
    //
    // Aynı çekirdeğe sahip ADAYLAR da birbirini eliyor: iki farklı remiks
    // ayrı ayrı kuyruğa girerse sonuç yine aynı.
    final cores = <Set<String>>[trackCore(seed.title)];
    final scored = <({VideoSummary video, int score})>[];
    for (final candidate in candidates) {
      final id = candidate.videoId;
      if (id == null || !seen.add(id)) continue;
      if (_isDuplicateTrack(cores, candidate.title)) continue;
      final score = similarityScore(seed, candidate);
      if (score < _minScore) continue;
      cores.add(trackCore(candidate.title));
      scored.add((video: candidate, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    final pool = scored.map((e) => e.video).toList();
    final result = <VideoSummary>[seed, ...episodes];

    // Bölüm dizisinden sonra üst üste aynı kanal sınırı DOLMUŞ sayılır:
    // bölümler bittiğinde kuyruk aynı kanalda devam etmek yerine açılsın.
    var lastChannel = result.last.uploaderName;
    var streak = episodes.isEmpty ? 1 : _maxConsecutiveSameChannel;

    while (pool.isNotEmpty && result.length < _maxQueueLength) {
      // En benzer adayla devam et; ama aynı kanaldan üst üste çalma sınırına
      // takılıyorsak sıradaki en benzer FARKLI kanalı seç.
      var pickIndex = 0;
      if (streak >= _maxConsecutiveSameChannel) {
        final alternative =
            pool.indexWhere((v) => v.uploaderName != lastChannel);
        if (alternative != -1) pickIndex = alternative;
      }

      final picked = pool.removeAt(pickIndex);
      if (picked.uploaderName == lastChannel) {
        streak++;
      } else {
        lastChannel = picked.uploaderName;
        streak = 1;
      }
      result.add(picked);
    }

    return result;
  }

  /// Kuyruk bitmek üzereyken sonuna eklenecek videoları seçer.
  ///
  /// Neden gerekli: kuyruk tek seferde kuruluyor ve sonuna gelindiğinde
  /// oynatma DURUYORDU. YouTube'da müzik dinlerken böyle bir son yok — kuyruk
  /// tükendikçe öneriyle uzuyor. Kullanıcı için fark, "bir süre sonra sessizlik"
  /// ile "dinlemeye devam" arasındaki fark.
  ///
  /// [current] o an çalan video (benzerlik bunun üzerinden ölçülüyor, kuyruğun
  /// ilk videosu üzerinden değil — yoksa kuyruk uzadıkça başlangıç noktasından
  /// kopardı). [existing] kuyrukta hâlihazırda olanlar; hiçbiri tekrar
  /// eklenmiyor. [candidates] genellikle çalan videonun ilgili videoları.
  ///
  /// Dönen liste kuyruğun SONUNA eklenecek olanlar; boş dönebilir (aday yoksa
  /// ya da hepsi zaten kuyrukta) ve o durumda kuyruk uzamaz.
  static List<VideoSummary> extend({
    required VideoSummary current,
    required List<VideoSummary> existing,
    required List<VideoSummary> candidates,
    int limit = _extendBatch,
  }) {
    final seen = <String>{
      if (current.videoId != null) current.videoId!,
      for (final video in existing)
        if (video.videoId != null) video.videoId!,
    };

    // Uzatmada da aynı kural: kuyruk uzarken aynı şarkının başka sürümleri
    // sızmamalı. Karşılaştırma kuyruktakilerin HEPSİNE karşı yapılıyor.
    final cores = <Set<String>>[
      trackCore(current.title),
      for (final video in existing) trackCore(video.title),
    ];
    final scored = <({VideoSummary video, int score})>[];
    for (final candidate in candidates) {
      final id = candidate.videoId;
      if (id == null || !seen.add(id)) continue;
      if (_isDuplicateTrack(cores, candidate.title)) continue;
      final score = similarityScore(current, candidate);
      if (score < _minScore) continue;
      cores.add(trackCore(candidate.title));
      scored.add((video: candidate, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    // Aynı kanal sınırı burada da geçerli, ama kuyruğun MEVCUT sonundan
    // devam ederek: eklenen ilk video kuyruktaki son videoyla aynı kanaldansa
    // bu üst üste sayılır.
    final pool = scored.map((e) => e.video).toList();
    final added = <VideoSummary>[];
    var lastChannel = existing.isEmpty ? null : existing.last.uploaderName;
    var streak = 1;

    while (pool.isNotEmpty && added.length < limit) {
      var pickIndex = 0;
      if (streak >= _maxConsecutiveSameChannel) {
        final alternative =
            pool.indexWhere((v) => v.uploaderName != lastChannel);
        if (alternative != -1) pickIndex = alternative;
      }
      final picked = pool.removeAt(pickIndex);
      if (picked.uploaderName == lastChannel) {
        streak++;
      } else {
        lastChannel = picked.uploaderName;
        streak = 1;
      }
      added.add(picked);
    }

    return added;
  }

  /// Kuyruğun sonuna bir seferde eklenen video sayısı.
  ///
  /// Küçük tutuluyor: her uzatma bir sonraki videonun ilgili listesinden
  /// besleniyor, yani kuyruk kullanıcı ilerledikçe kendi kendini tazeliyor.
  /// Büyük paketler eski bir videonun önerilerini kuyruğun çok ilerisine
  /// taşırdı.
  static const _extendBatch = 10;

  /// Kuyruğun mutlak üst sınırı.
  ///
  /// Sonsuz uzama bellek ve native tarafa gönderilen liste boyutu demek;
  /// bu sınıra gelince en baştaki (çoktan çalınmış) videolar düşürülüyor.
  static const maxTotalQueueLength = 200;

  /// [title], [cores] içindeki parçalardan birinin başka bir sürümü mü.
  static bool _isDuplicateTrack(List<Set<String>> cores, String title) {
    final core = trackCore(title);
    if (core.isEmpty) return false;
    for (final other in cores) {
      if (other.length == core.length && other.containsAll(core)) return true;
    }
    return false;
  }

  /// İzleme geçmişindeki video kimlikleri.
  ///
  /// Yalnızca bellekteki listeyi okur (disk erişimi yok), bu yüzden kuyruk
  /// kurmayı yavaşlatmaz.
  static Set<String> _watchedVideoIds() => {
        for (final video in LibraryStore.instance.watched)
          if (video.videoId != null) video.videoId!,
      };
}
