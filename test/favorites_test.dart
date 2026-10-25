import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:olustiff/core/data/library_store.dart';
import 'package:olustiff/core/extraction/models.dart';

VideoSummary video(String id) => VideoSummary.fromMap({
      'videoId': id,
      'title': 'Şarkı $id',
      'url': 'https://www.youtube.com/watch?v=$id',
      'uploaderName': 'Kanal',
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
    for (final v in LibraryStore.instance.favorites.toList()) {
      await LibraryStore.instance.toggleFavorite(v);
    }
  });

  test('kalp ekler, ikinci dokunuş çıkarır', () async {
    final store = LibraryStore.instance;
    expect(await store.toggleFavorite(video('a')), isTrue);
    expect(store.isFavorite('a'), isTrue);
    expect(await store.toggleFavorite(video('a')), isFalse);
    expect(store.isFavorite('a'), isFalse);
    expect(store.favorites, isEmpty);
  });

  test('en son eklenen başta, aynı şarkı iki kez girmez', () async {
    final store = LibraryStore.instance;
    await store.toggleFavorite(video('a'));
    await store.toggleFavorite(video('b'));
    expect(store.favorites.map((v) => v.videoId), ['b', 'a']);
  });

  test('favoriler uygulama yeniden açılınca kalır', () async {
    final store = LibraryStore.instance;
    await store.toggleFavorite(video('a'));
    await store.load();
    expect(store.favorites.map((v) => v.videoId), ['a']);
  });

  test('çok dinlenmek favoriye eklemez', () async {
    final store = LibraryStore.instance;
    await store.recordWatch(video('x'));
    await store.recordWatch(video('x'));
    await store.recordWatch(video('x'));
    expect(store.isFavorite('x'), isFalse,
        reason: 'Favoriler yalnızca kalple işaretlenenler');
  });
}
