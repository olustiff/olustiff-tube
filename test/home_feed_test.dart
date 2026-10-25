import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:olustiff/core/data/library_store.dart';
import 'package:olustiff/core/extraction/extraction_client.dart';
import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/features/home/home_feed.dart';

VideoSummary video(String id, String title, String uploader) =>
    VideoSummary.fromMap({
      'videoId': id,
      'title': title,
      'url': 'https://www.youtube.com/watch?v=$id',
      'uploaderName': uploader,
      'durationSeconds': 120,
      'viewCount': 10,
      'textualUploadDate': null,
      'thumbnailUrl': null,
    });

/// Ağ yerine elle verilen sonuçlar. Anahtar video kimliği (benzerleri) ya da
/// arama metni; değer sonuç listesi ya da fırlatılacak hata.
class _FakeClient extends ExtractionClient {
  _FakeClient(this.results);

  final Map<String, Object> results;
  final requested = <String>[];

  List<VideoSummary> _answer(String key) {
    requested.add(key);
    final r = results[key];
    if (r is Exception) throw r;
    return r as List<VideoSummary>? ?? const [];
  }

  @override
  Future<PagedVideos> search(String query, {bool keepSession = true}) async =>
      PagedVideos(items: _answer(query), hasMore: false);

  @override
  Future<VideoDetails> videoDetails(String videoId) async =>
      VideoDetails.fromMap({'videoId': videoId, 'title': ''})
          .withRelated(_answer(videoId));
}

extension on VideoDetails {
  VideoDetails withRelated(List<VideoSummary> related) => VideoDetails(
        videoId: videoId,
        title: title,
        uploaderName: uploaderName,
        uploaderUrl: uploaderUrl,
        durationSeconds: durationSeconds,
        viewCount: viewCount,
        description: description,
        category: category,
        tags: tags,
        isLive: isLive,
        thumbnailUrl: thumbnailUrl,
        hlsUrl: hlsUrl,
        dashMpdUrl: dashMpdUrl,
        videoStreams: videoStreams,
        videoOnlyStreams: videoOnlyStreams,
        audioStreams: audioStreams,
        relatedItems: related,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.instance.load();
    // LibraryStore bir singleton: testler arasında geçmiş sızmasın.
    await LibraryStore.instance.clearSearches();
    await LibraryStore.instance.clearWatched();
    for (final v in LibraryStore.instance.favorites.toList()) {
      await LibraryStore.instance.toggleFavorite(v);
    }
  });

  test('akış DİNLENENLERDEN kurulur, aramalardan değil', () async {
    final store = LibraryStore.instance;
    await store.recordSearch('bir kez aranıp beğenilmeyen');
    await store.recordWatch(video('d1', 'Dinlenen', 'Kanal'));

    final seeds = HomeFeed().seeds();

    expect(seeds, contains(const FeedSeed.video('d1')));
    expect(seeds.where((s) => !s.isVideo), isEmpty);
  });

  test('tohumlar: favori, çok dinlenen, son dinlenen — her birinden en çok 2',
      () async {
    final store = LibraryStore.instance;
    for (final id in ['f1', 'f2', 'f3']) {
      await store.toggleFavorite(video(id, 'Fav $id', 'K'));
    }
    // m1 üç kez: en çok dinlenen.
    for (var i = 0; i < 3; i++) {
      await store.recordWatch(video('m1', 'Çok dinlenen', 'K'));
    }
    await store.recordWatch(video('r1', 'Son 1', 'K'));
    await store.recordWatch(video('r2', 'Son 2', 'K'));

    final ids = HomeFeed().seeds().map((s) => s.value).toList();

    expect(ids.where((id) => id.startsWith('f')).length, 2,
        reason: 'tek kaynak akışı tek sanatçıya kilitlemesin');
    expect(ids, contains('m1'));
    expect(ids, contains('r2'));
    expect(ids.length, lessThanOrEqualTo(5));
    expect(ids.toSet().length, ids.length, reason: 'aynı tohum iki kez yok');
  });

  test('dinleme geçmişi yoksa son aramalar yedek tohum olur', () async {
    await LibraryStore.instance.recordSearch('sezen aksu');
    expect(HomeFeed().seeds(), [const FeedSeed.search('sezen aksu')],
        reason: 'yeni kullanıcının ana sayfası boş kalmamalı');
  });

  test('benzerler serpiştirilir; bilinenler ve aynı şarkının sürümleri elenir',
      () async {
    final store = LibraryStore.instance;
    await store.recordWatch(video('a', 'Tarkan - Kuzu Kuzu', 'Tarkan'));
    await store.recordWatch(video('b', 'Sezen Aksu - Gülümse', 'Sezen'));

    final feed = HomeFeed(
      client: _FakeClient({
        'b': [
          video('s1', 'Sezen Aksu - Firuze', 'Sezen'),
          video('s2', 'Sezen Aksu - Gülümse (Canlı)', 'X'), // dinlenenin sürümü
        ],
        'a': [
          video('a', 'Tarkan - Kuzu Kuzu', 'Tarkan'), // zaten dinlendi
          video('t1', 'Tarkan - Şımarık', 'Tarkan'),
          video('t2', 'Tarkan - Şımarık (Lyrics)', 'Y'), // aynı şarkı
        ],
      }),
    );
    final ids = (await feed.load()).map((v) => v.videoId).toList();

    expect(ids, ['s1', 't1']);
  });

  // Gerçekte yaşanan: açılışta internet yoktu, her istek hata verdi ve ana
  // sayfa "öneri yok" diye BOŞ kaldı; internet gelince de dolmadı.
  test('tüm istekler hata verirse akış boş değil HATA döner', () async {
    await LibraryStore.instance.recordWatch(video('a', 'A şarkısı', 'K'));
    await LibraryStore.instance.recordWatch(video('b', 'B şarkısı', 'K'));
    final feed = HomeFeed(
      client: _FakeClient({
        'a': Exception('ağ yok'),
        'b': Exception('ağ yok'),
      }),
    );
    await expectLater(feed.load(), throwsException);
  });

  test('bir istek hata verse de diğerleriyle akış dolar', () async {
    await LibraryStore.instance.recordWatch(video('a', 'A şarkısı', 'K'));
    await LibraryStore.instance.recordWatch(video('b', 'B şarkısı', 'K'));
    final feed = HomeFeed(
      client: _FakeClient({
        'a': Exception('ağ yok'),
        'b': [video('s1', 'Gülümse', 'Sezen Aksu')],
      }),
    );
    final videos = await feed.load();
    expect(videos.map((v) => v.videoId), ['s1']);
  });

  test('geçmiş silinince tohum geçersiz olur (akış yenilenir)', () async {
    final store = LibraryStore.instance;
    await store.recordWatch(video('a', 'A şarkısı', 'K'));
    final feed = HomeFeed();
    final seed = feed.seeds().single;
    expect(feed.isStillInHistory(seed), isTrue);

    await store.clearWatched();
    expect(feed.isStillInHistory(seed), isFalse);
  });

  test('son akış saklanır, geçmiş silinince o da silinir', () async {
    final store = LibraryStore.instance;
    await store.saveFeedCache([video('a', 'Şarkı', 'Kanal')]);
    await store.load(); // uygulama yeniden açıldı
    expect(store.feedCache.map((v) => v.videoId), ['a']);

    await store.clearWatched();
    expect(store.feedCache, isEmpty);
  });
}
