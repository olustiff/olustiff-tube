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
    final scored = <({VideoSummary video, int score})>[];
    for (final candidate in candidates) {
      final id = candidate.videoId;
      if (id == null || !seen.add(id)) continue;
      final score = similarityScore(seed, candidate);
      if (score < _minScore) continue;
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

  /// İzleme geçmişindeki video kimlikleri.
  ///
  /// Yalnızca bellekteki listeyi okur (disk erişimi yok), bu yüzden kuyruk
  /// kurmayı yavaşlatmaz.
  static Set<String> _watchedVideoIds() => {
        for (final video in LibraryStore.instance.watched)
          if (video.videoId != null) video.videoId!,
      };
}
