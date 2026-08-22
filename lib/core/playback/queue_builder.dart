import '../extraction/models.dart';

/// Oynatma kuyruğunu, "radyo" hissi verecek şekilde kurar.
///
/// Sorun: bir arama sonucunu doğrudan kuyruk yapmak aynı sanatçının aynı
/// şarkılarını arka arkaya çalar ("Selena Gomez" arayınca sadece Selena Gomez).
/// Çözüm: aday havuzunu ilgili/önerilen videolarla genişletip aynı kanaldan
/// arka arkaya çalmayı sınırlamak.
class QueueBuilder {
  /// Aynı kanaldan üst üste en fazla kaç video çalabileceği.
  static const _maxConsecutiveSameChannel = 1;

  /// Kuyruğun üst sınırı; çok uzun kuyruk hem gereksiz hem yönetilemez.
  static const _maxQueueLength = 50;

  /// [seed] çalınan video, [candidates] aday havuzu (arama sonuçları ve/veya
  /// ilgili videolar). Sonuç, [seed] ile başlayan karışık bir sıradır.
  static List<VideoSummary> build({
    required VideoSummary seed,
    required List<VideoSummary> candidates,
  }) {
    final seen = <String>{if (seed.videoId != null) seed.videoId!};
    final pool = <VideoSummary>[];
    for (final candidate in candidates) {
      final id = candidate.videoId;
      if (id == null || !seen.add(id)) continue;
      pool.add(candidate);
    }

    final result = <VideoSummary>[seed];
    var lastChannel = seed.uploaderName;
    var streak = 1;

    while (pool.isNotEmpty && result.length < _maxQueueLength) {
      // Aynı kanaldan üst üste çalma sınırına takılmayan ilk adayı seç;
      // yoksa sırayı bozmamak için ilk adayı al.
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
