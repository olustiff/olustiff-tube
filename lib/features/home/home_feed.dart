import 'dart:math';

import '../../core/data/library_store.dart';
import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';

/// Ana sayfa akışını kullanıcının geçmişinden üretir.
///
/// Trend listesi yerine: son aramalar ve son izlenenler tohum olarak alınır,
/// bunlardan arama yapılıp sonuçlar karıştırılır. Böylece ana sayfa kişisel
/// olur ve hep aynı sanatçı yerine benzer içerikler de gelir.
class HomeFeed {
  HomeFeed({ExtractionClient? client, LibraryStore? library})
      : _client = client ?? ExtractionClient(),
        _library = library ?? LibraryStore.instance;

  final ExtractionClient _client;
  final LibraryStore _library;

  /// Kaç farklı tohumdan arama yapılacağı. Fazlası hem yavaş hem gereksiz.
  static const _seedCount = 4;

  /// Geçmiş boşsa akış da boştur; çağıran taraf kullanıcıyı aramaya yönlendirir.
  bool get hasHistory =>
      _library.searches.isNotEmpty || _library.watched.isNotEmpty;

  /// Tohumlar: önce son aramalar, sonra EN ÇOK dinlenen kanallar.
  ///
  /// Sık dinlenen sanatçı, sadece bir kez açılmış bir kanaldan daha isabetli
  /// öneri verir; bu yüzden izleme sayacına göre sıralanır.
  List<String> seeds() {
    final result = <String>[];
    for (final search in _library.searches) {
      if (result.length >= _seedCount) break;
      result.add(search);
    }
    for (final channel in _library.topChannels) {
      if (result.length >= _seedCount) break;
      if (channel.isEmpty) continue;
      if (result.any((s) => s.toLowerCase() == channel.toLowerCase())) continue;
      result.add(channel);
    }
    return result;
  }

  /// Tohumlardan arama yapıp sonuçları serpiştirir.
  ///
  /// Serpiştirme önemli: sonuçları uç uca eklemek ana sayfayı "önce hep şu
  /// arama, sonra hep bu arama" haline getirirdi.
  Future<List<VideoSummary>> load() async {
    final seedList = seeds();
    if (seedList.isEmpty) return const [];

    final results = <List<VideoSummary>>[];
    for (final seed in seedList) {
      try {
        final page = await _client.search(seed);
        if (page.items.isNotEmpty) results.add(page.items);
      } catch (_) {
        // Tek bir tohum başarısız olursa akışın tamamı çökmesin.
      }
    }
    if (results.isEmpty) return const [];

    final watchedIds = _library.watched
        .map((v) => v.videoId)
        .whereType<String>()
        .toSet();

    final merged = <VideoSummary>[];
    final seen = <String>{};
    final maxLength = results.map((r) => r.length).reduce(max);

    for (var i = 0; i < maxLength; i++) {
      for (final list in results) {
        if (i >= list.length) continue;
        final video = list[i];
        final id = video.videoId;
        if (id == null || !seen.add(id)) continue;
        // Yeni izlenenleri tekrar önermek akışı bayatlatır.
        if (watchedIds.contains(id)) continue;
        merged.add(video);
      }
    }
    return merged;
  }
}
