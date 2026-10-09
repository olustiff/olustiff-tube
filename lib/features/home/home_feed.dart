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

  /// Tohumlar: kullanıcının SON ARAMALARI.
  ///
  /// Akış aramaya göre kurulur. Kanal adlarını da tohum yapmak, aranmamış
  /// içerikleri ana sayfaya taşıyordu: bir videonun kanalı çoğu zaman
  /// sanatçının adı değil ("... VEVO", "Topic", derleme kanalları) ve
  /// oradan gelen sonuçlar kullanıcının aradığı şeyle ilgisiz kalıyordu.
  ///
  /// Kanallar yalnızca hiç arama yapılmamışken yedek olarak kullanılır —
  /// aksi halde ana sayfa bomboş kalırdı.
  List<String> seeds() {
    final searches = _library.searches.take(_seedCount).toList();
    if (searches.isNotEmpty) return searches;

    return _library.topChannels
        .where((channel) => channel.isNotEmpty)
        .take(_seedCount)
        .toList();
  }

  /// Tohumlardan arama yapıp sonuçları serpiştirir.
  ///
  /// Serpiştirme önemli: sonuçları uç uca eklemek ana sayfayı "önce hep şu
  /// arama, sonra hep bu arama" haline getirirdi.
  Future<List<VideoSummary>> load() async {
    final seedList = seeds();
    if (seedList.isEmpty) return const [];

    // Tohumlar AYNI ANDA aranıyor, sırayla değil.
    //
    // Seri döngü açılışın en pahalı kısmıydı: dört YouTube araması art arda
    // yapılıyor ve ana sayfada içerik görünene kadar hepsinin bitmesi
    // bekleniyordu. Paralelde süre en yavaş isteğinkine iniyor.
    //
    // `Future.wait` sırayı koruyor; serpiştirme buna dayandığı için şart.
    final pages = await Future.wait(
      seedList.map((seed) async {
        try {
          return (await _client.search(seed)).items;
        } catch (_) {
          // Tek bir tohum başarısız olursa akışın tamamı çökmesin.
          return const <VideoSummary>[];
        }
      }),
    );
    final results = pages.where((page) => page.isNotEmpty).toList();
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
