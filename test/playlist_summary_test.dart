import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/core/extraction/models.dart';

void main() {
  group('arama sonucundaki çalma listesi', () {
    test('alanlar okunur', () {
      final p = PlaylistSummary.fromMap({
        'title': 'Türkçe Pop 2026',
        'url': 'https://www.youtube.com/playlist?list=PL123',
        'uploaderName': 'Bir Kanal',
        'streamCount': 42,
        'thumbnailUrl': 'https://i.ytimg.com/x.jpg',
      });
      expect(p.title, 'Türkçe Pop 2026');
      expect(p.url, 'https://www.youtube.com/playlist?list=PL123');
      expect(p.uploaderName, 'Bir Kanal');
      expect(p.streamCount, 42);
    });

    // NewPipe bilinmeyen sayıyı -1 ile bildiriyor; olduğu gibi göstermek
    // "-1 video" yazdırırdı, 0'a çevirmek de listeyi boş sanmaya yol açardı.
    test('bilinmeyen video sayısı null olur', () {
      expect(
        PlaylistSummary.fromMap({'title': 'x', 'streamCount': -1}).streamCount,
        isNull,
      );
      expect(
        PlaylistSummary.fromMap({'title': 'x'}).streamCount,
        isNull,
      );
    });

    test('eksik alanlar çökertmez', () {
      final p = PlaylistSummary.fromMap({});
      expect(p.title, '');
      expect(p.url, '');
      expect(p.uploaderName, isNull);
      expect(p.thumbnailUrl, isNull);
    });
  });

  group('sayfa sonucu', () {
    test('videolar ve listeler ayrı okunur', () {
      final page = PagedVideos.fromMap({
        'items': [
          {'videoId': 'a', 'title': 'Video A'},
        ],
        'playlists': [
          {'title': 'Liste', 'url': 'u', 'streamCount': 3},
        ],
        'hasMore': true,
      });
      expect(page.items, hasLength(1));
      expect(page.playlists, hasLength(1));
      expect(page.playlists.single.streamCount, 3);
      expect(page.hasMore, isTrue);
    });

    // Trend ve çalma listesi içeriği "playlists" alanını hiç göndermiyor.
    test('liste alanı yoksa boş kalır', () {
      final page = PagedVideos.fromMap({'items': const [], 'hasMore': false});
      expect(page.playlists, isEmpty);
    });
  });
}
