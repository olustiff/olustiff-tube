import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:olustiff/core/data/library_store.dart';
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
}
