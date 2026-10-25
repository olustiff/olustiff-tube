import 'dart:math';

import '../../core/data/library_store.dart';
import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/similarity.dart';

/// Akışın neye dayanarak kurulduğu: bir video (benzerleri alınır) ya da bir
/// arama metni (yalnızca dinleme geçmişi boşken yedek).
class FeedSeed {
  const FeedSeed.video(this.value) : isVideo = true;
  const FeedSeed.search(this.value) : isVideo = false;

  /// Video kimliği ya da arama metni.
  final String value;
  final bool isVideo;

  @override
  bool operator ==(Object other) =>
      other is FeedSeed && other.value == value && other.isVideo == isVideo;

  @override
  int get hashCode => Object.hash(value, isVideo);

  @override
  String toString() => isVideo ? 'video:$value' : 'arama:$value';
}

/// Ana sayfa akışını ("Sana özel") kullanıcının DİNLEDİKLERİNDEN üretir.
///
/// Tohumlar dinlenen/izlenen videolar; her birinin YouTube'daki "benzer
/// videolar" listesi alınıp serpiştiriliyor. Önceden tohum arama
/// geçmişiydi: bir kez aranıp beğenilmeyen bir şey bile ana sayfaya
/// taşınıyordu, oysa asıl ilgi göstergesi dinlenen şey.
///
/// Kanal ADI bilerek tohum yapılmıyor: bir videonun kanalı çoğu zaman
/// sanatçı değil ("... VEVO", "Topic", derleme kanalları) ve kanal adıyla
/// arama alakasız sonuç getiriyordu. Benzer videolar listesi bu sorunu
/// taşımıyor: YouTube onu videonun kendisine göre veriyor.
class HomeFeed {
  HomeFeed({ExtractionClient? client, LibraryStore? library})
      : _client = client ?? ExtractionClient(),
        _library = library ?? LibraryStore.instance;

  final ExtractionClient _client;
  final LibraryStore _library;

  /// Toplam tohum. Her biri tam bir video çözümlemesi (benzerler oradan
  /// geliyor), fazlası açılışı yavaşlatır.
  static const _seedCount = 5;

  /// Geçmiş boşsa akış da boştur; çağıran taraf kullanıcıyı aramaya yönlendirir.
  bool get hasHistory =>
      _library.searches.isNotEmpty ||
      _library.watched.isNotEmpty ||
      _library.favorites.isNotEmpty;

  /// Tohumlar, güçlü ilgiden zayıfa:
  /// - favoriler (kullanıcı bilerek kalpledi),
  /// - en çok tekrar dinlenenler,
  /// - en son dinlenenler (şu anki ruh hali).
  ///
  /// Her kaynaktan en fazla iki tane: biri listeyi tek başına doldurursa akış
  /// tek bir sanatçıya kilitlenir. Dinleme geçmişi hiç yoksa son aramalar
  /// yedek tohum olur — yoksa yeni kullanıcının ana sayfası boş kalırdı.
  List<FeedSeed> seeds() {
    final ids = <String>[];
    void take(Iterable<VideoSummary> source, int count) {
      var taken = 0;
      for (final video in source) {
        if (taken >= count || ids.length >= _seedCount) return;
        final id = video.videoId;
        if (id == null || ids.contains(id)) continue;
        ids.add(id);
        taken++;
      }
    }

    take(_library.favorites, 2);
    take(_library.mostPlayed, 2);
    take(_library.watched, 2);
    if (ids.isNotEmpty) return ids.map(FeedSeed.video).toList();

    return _library.searches
        .take(_seedCount)
        .map(FeedSeed.search)
        .toList();
  }

  /// Tohum hâlâ geçmişte mi. Geçmiş silinince akış yenilensin diye; YENİ
  /// dinlenen bir şarkı akışı her seferinde baştan kurdurmasın diye de
  /// yalnızca bu soruluyor.
  bool isStillInHistory(FeedSeed seed) {
    if (!seed.isVideo) return _library.searches.contains(seed.value);
    bool has(Iterable<VideoSummary> list) =>
        list.any((v) => v.videoId == seed.value);
    return has(_library.favorites) || has(_library.watched);
  }

  Future<List<VideoSummary>> _resultsFor(FeedSeed seed) async {
    if (seed.isVideo) {
      return (await _client.videoDetails(seed.value)).relatedItems;
    }
    return (await _client.search(seed.value, keepSession: false)).items;
  }

  /// Tohumlardan sonuçları alıp serpiştirir.
  ///
  /// Serpiştirme önemli: sonuçları uç uca eklemek ana sayfayı "önce hep şu
  /// şarkının benzerleri, sonra hep bunun" haline getirirdi.
  Future<List<VideoSummary>> load() async {
    final seedList = seeds();
    if (seedList.isEmpty) return const [];

    // Tohumlar AYNI ANDA isteniyor, sırayla değil: süre en yavaş isteğinkine
    // iniyor. `Future.wait` sırayı koruyor; serpiştirme buna dayanıyor.
    Object? lastError;
    final pages = await Future.wait(
      seedList.map((seed) async {
        try {
          return await _resultsFor(seed);
        } catch (e) {
          // Tek bir tohum başarısız olursa akışın tamamı çökmesin.
          lastError = e;
          return const <VideoSummary>[];
        }
      }),
    );
    final results = pages.where((page) => page.isNotEmpty).toList();
    // HEPSİ hata verdiyse bu "öneri yok" değil, "ulaşılamadı": boş liste
    // döndürmek ana sayfayı sessizce boş bırakıyordu (açılışta internet
    // yokken). Hata fırlatılınca ekran önbelleği tutuyor ve yeniden deniyor.
    if (results.isEmpty && lastError != null) throw lastError!;
    if (results.isEmpty) return const [];

    // Zaten bilinenler önerilmez: akış YENİ şeyler göstermeli.
    final known = [..._library.watched, ..._library.favorites];
    final knownIds = known.map((v) => v.videoId).whereType<String>().toSet();
    final knownTitles = known.map((v) => v.title).toList();

    final merged = <VideoSummary>[];
    final seen = <String>{};
    final maxLength = results.map((r) => r.length).reduce(max);

    for (var i = 0; i < maxLength; i++) {
      for (final list in results) {
        if (i >= list.length) continue;
        final video = list[i];
        final id = video.videoId;
        if (id == null || !seen.add(id)) continue;
        if (knownIds.contains(id)) continue;
        // Aynı şarkının başka bir yüklemesi (klip/remiks/sözlü) de bilinen
        // sayılır; benzerler listesi bunlarla dolu geliyor.
        if (knownTitles.any((t) => isSameTrack(t, video.title))) continue;
        if (merged.any((v) => isSameTrack(v.title, video.title))) continue;
        merged.add(video);
      }
    }
    return merged;
  }
}
