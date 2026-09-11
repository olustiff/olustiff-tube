import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/features/search/channel_screen.dart';

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

  group('arama sonucundaki kanal', () {
    test('alanlar okunur', () {
      final c = ChannelSummary.fromMap({
        'name': 'RAIKAHO',
        'url': 'https://www.youtube.com/@raikaho',
        'subscriberCount': 2100000,
        'streamCount': 180,
        'verified': true,
        'thumbnailUrl': 'https://yt3.ggpht.com/x',
      });
      expect(c.name, 'RAIKAHO');
      expect(c.subscriberCount, 2100000);
      expect(c.streamCount, 180);
      expect(c.verified, isTrue);
    });

    test('bilinmeyen sayılar null olur', () {
      final c = ChannelSummary.fromMap({
        'name': 'x',
        'subscriberCount': -1,
        'streamCount': -1,
      });
      expect(c.subscriberCount, isNull);
      expect(c.streamCount, isNull);
      expect(c.verified, isFalse);
    });

    test('sayfa sonucunda kanallar ayrı okunur', () {
      final page = PagedVideos.fromMap({
        'items': const [],
        'channels': [
          {'name': 'Kanal', 'url': 'u', 'subscriberCount': 500},
        ],
        'hasMore': false,
      });
      expect(page.channels, hasLength(1));
      expect(page.channels.single.subscriberCount, 500);
    });
  });

  group('abone sayısı biçimi', () {
    test('binin altı olduğu gibi yazılır', () {
      expect(formatCompactCount(0), '0');
      expect(formatCompactCount(999), '999');
    });

    // 10 binin altında ondalık anlamlı, üstünde gürültü.
    test('binler kısaltılır', () {
      expect(formatCompactCount(1500), '1,5 B');
      expect(formatCompactCount(9400), '9,4 B');
      expect(formatCompactCount(94000), '94 B');
    });

    test('milyonlar kısaltılır', () {
      expect(formatCompactCount(2100000), '2,1 Mn');
      expect(formatCompactCount(23000000), '23 Mn');
    });
  });
}
