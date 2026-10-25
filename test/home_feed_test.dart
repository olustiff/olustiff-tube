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

/// Ağ yerine elle verilen sonuçlar: tohum → sonuç, ya da hata.
class _FakeClient extends ExtractionClient {
  _FakeClient(this.results);

  final Map<String, Object> results;

  @override
  Future<PagedVideos> search(String query, {bool keepSession = true}) async {
    final r = results[query];
    if (r is Exception) throw r;
    return PagedVideos(items: r as List<VideoSummary>? ?? const [], hasMore: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.instance.load();
    // LibraryStore bir singleton: testler arasında geçmiş sızmasın.
    await LibraryStore.instance.clearSearches();
    await LibraryStore.instance.clearWatched();
  });

  test('akış tohumları kullanıcının aramalarından gelir', () async {
    final store = LibraryStore.instance;
    await store.recordSearch('selena gomez');
    await store.recordSearch('sezen aksu');
    // İzlenen videonun kanalı aramaya benzemiyor: derleme/VEVO kanalları
    // ana sayfayı alakasız içerikle dolduruyordu.
    await store.recordWatch(video('x', 'Bir şey', 'Various Artists - Topic'));
    await store.recordWatch(video('x', 'Bir şey', 'Various Artists - Topic'));

    final seeds = HomeFeed().seeds();

    expect(seeds, contains('selena gomez'));
    expect(seeds, contains('sezen aksu'));
    expect(seeds, isNot(contains('Various Artists - Topic')),
        reason: 'akış aramaya göre kurulur, kanal adına göre değil');
  });

  test('hiç arama yoksa akış en çok dinlenen kanaldan kurulur', () async {
    final store = LibraryStore.instance;
    await store.recordWatch(video('a', 'Şarkı', 'Çok Kanal'));
    await store.recordWatch(video('a', 'Şarkı', 'Çok Kanal'));

    expect(HomeFeed().seeds(), contains('Çok Kanal'),
        reason: 'arama geçmişi boşken ana sayfa bomboş kalmamalı');
  });

  // Gerçekte yaşanan: açılışta internet yoktu, her arama hata verdi ve ana
  // sayfa "öneri yok" diye BOŞ kaldı; internet gelince de dolmadı.
  test('tüm aramalar hata verirse akış boş değil HATA döner', () async {
    await LibraryStore.instance.recordSearch('tarkan');
    await LibraryStore.instance.recordSearch('sezen aksu');
    final feed = HomeFeed(
      client: _FakeClient({
        'tarkan': Exception('ağ yok'),
        'sezen aksu': Exception('ağ yok'),
      }),
    );
    await expectLater(feed.load(), throwsException);
  });

  test('bir arama hata verse de diğerleriyle akış dolar', () async {
    await LibraryStore.instance.recordSearch('tarkan');
    await LibraryStore.instance.recordSearch('sezen aksu');
    final feed = HomeFeed(
      client: _FakeClient({
        'tarkan': Exception('ağ yok'),
        'sezen aksu': [video('s1', 'Gülümse', 'Sezen Aksu')],
      }),
    );
    final videos = await feed.load();
    expect(videos.map((v) => v.videoId), ['s1']);
  });

  test('son akış saklanır, arama geçmişi silinince o da silinir', () async {
    final store = LibraryStore.instance;
    await store.saveFeedCache([video('a', 'Şarkı', 'Kanal')]);
    await store.load(); // uygulama yeniden açıldı
    expect(store.feedCache.map((v) => v.videoId), ['a']);

    await store.clearSearches();
    expect(store.feedCache, isEmpty,
        reason: '"Ana sayfa önerileri de sıfırlanır" deniyor');
  });
}
