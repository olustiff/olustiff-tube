import '../extraction/models.dart';
import 'similarity.dart';

/// Oynatma kuyruğunu, "radyo" hissi verecek şekilde kurar.
///
/// İki şeyi birden dengeler:
/// - **Benzerlik**: kuyruk aynı dilde ve yakın tarzda kalmalı. Alakasız
///   içerik (başka bir dilde şarkı, saatlik bir mix) araya girerse kullanıcı
///   sıkılır.
/// - **Çeşitlilik**: aynı sanatçının şarkıları arka arkaya yığılmamalı —
///   "Selena Gomez" arayınca kuyruk baştan sona Selena Gomez olmamalı.
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

  /// [seed] çalınan video, [candidates] aday havuzu (arama sonuçları ve/veya
  /// ilgili videolar). Sonuç, [seed] ile başlayan benzer ama tekdüze olmayan
  /// bir sıradır.
  static List<VideoSummary> build({
    required VideoSummary seed,
    required List<VideoSummary> candidates,
  }) {
    final seen = <String>{if (seed.videoId != null) seed.videoId!};

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
    final result = <VideoSummary>[seed];
    var lastChannel = seed.uploaderName;
    var streak = 1;

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
}
