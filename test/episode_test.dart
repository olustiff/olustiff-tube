import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/core/playback/episode.dart';

VideoSummary v(
  String id, {
  required String title,
  String uploader = 'Kanal D',
  int duration = 7200,
  int views = 0,
}) =>
    VideoSummary(
      videoId: id,
      title: title,
      url: 'https://www.youtube.com/watch?v=$id',
      uploaderName: uploader,
      durationSeconds: duration,
      viewCount: views,
      textualUploadDate: null,
      thumbnailUrl: null,
    );

void main() {
  group('parseEpisode — Türkçe kalıplar', () {
    test('"1. Bölüm"', () {
      final ref = parseEpisode('Arka Sıradakiler 1. Bölüm');
      expect(ref, isNotNull);
      expect(ref!.episode, 1);
      expect(ref.season, isNull);
      expect(ref.series, {'arka', 'siradakiler'});
    });

    test('"45.Bölüm (Final)" — noktadan sonra boşluksuz', () {
      final ref = parseEpisode('Kuruluş Osman 45.Bölüm (Final)');
      expect(ref?.episode, 45);
      expect(ref?.series, {'kurulus', 'osman'});
    });

    test('"2. Sezon 5. Bölüm"', () {
      final ref = parseEpisode('Teşkilat 2. Sezon 5. Bölüm');
      expect(ref?.season, 2);
      expect(ref?.episode, 5);
      // Sezon işareti başlıkta önce geçtiği için dizi adı ondan öncesi.
      expect(ref?.series, {'teskilat'});
    });

    test('"Bölüm 12" — numara kelimeden sonra', () {
      final ref = parseEpisode('Maraşlı Bölüm 12');
      expect(ref?.episode, 12);
      expect(ref?.series, {'marasli'});
    });

    test('"S02E05"', () {
      final ref = parseEpisode('Kuruluş Osman S02E05');
      expect(ref?.season, 2);
      expect(ref?.episode, 5);
      expect(ref?.series, {'kurulus', 'osman'});
    });

    test('bölüm işareti başta ise dizi adı arkadan okunur', () {
      final ref = parseEpisode('S02E05 | Kuruluş Osman');
      expect(ref?.episode, 5);
      expect(ref?.series, {'kurulus', 'osman'});
    });

    test('"Sezon 3 Bölüm 8"', () {
      final ref = parseEpisode('Yargı Sezon 3 Bölüm 8');
      expect(ref?.season, 3);
      expect(ref?.episode, 8);
    });

    test('"Episode 5" (İngilizce)', () {
      final ref = parseEpisode('Ottoman Rising Episode 5');
      expect(ref?.episode, 5);
    });

    test('büyük harf ve Türkçe karakterler aynı sonucu verir', () {
      final upper = parseEpisode('KURULUŞ OSMAN 12. BÖLÜM');
      final ascii = parseEpisode('Kurulus Osman 12. Bolum');
      expect(upper?.episode, 12);
      expect(ascii?.episode, 12);
      expect(upper?.series, ascii?.series);
    });

    test('pazarlama ekleri dizi adına karışmaz', () {
      final plain = parseEpisode('Arka Sıradakiler 3. Bölüm');
      final noisy =
          parseEpisode('Arka Sıradakiler Dizisi 3. Bölüm Full HD İzle');
      expect(noisy?.series, plain?.series);
    });

    test('bölüm başlığı dizi adına karışmaz', () {
      final ref = parseEpisode('Arka Sıradakiler 4. Bölüm - Cem\'in Kararı');
      expect(ref?.series, {'arka', 'siradakiler'});
    });
  });

  group('parseEpisode — bölüm sayılmayanlar', () {
    test('numarasız başlıkta bölüm yok', () {
      expect(parseEpisode('Sezen Aksu - Gülümse'), isNull);
      expect(parseEpisode('Arka Sıradakiler Son Bölüm'), isNull);
    });

    test('fragman/tanıtım bölüm sayılmaz', () {
      expect(parseEpisode('Kuruluş Osman 46. Bölüm Fragmanı'), isNull);
      expect(parseEpisode('Teşkilat 5. Bölüm 2. Tanıtımı'), isNull);
      expect(parseEpisode('Yargı 3. Bölüm Özeti'), isNull);
      expect(parseEpisode('Maraşlı 7. Bölüm | Kamera Arkası'), isNull);
    });

    test('dizi adı olmayan başlıkta bölüm yok', () {
      // Geriye anlamlı bir gövde kalmıyorsa hangi diziye ait olduğu bilinemez.
      expect(parseEpisode('5. Bölüm'), isNull);
      expect(parseEpisode('Bölüm 12 Full HD İzle'), isNull);
    });

    test('yıl gibi büyük sayılar bölüm sayılmaz', () {
      expect(parseEpisode('Kanal D Arşiv 2024 Bölüm'), isNull);
    });
  });

  group('episodeRunFor', () {
    test('sıradaki bölüm kuyruğun başına, artan sırada gelir', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('e54', title: 'Arka Sıradakiler 54. Bölüm'),
          v('e3', title: 'Arka Sıradakiler 3. Bölüm'),
          v('e2', title: 'Arka Sıradakiler 2. Bölüm'),
          v('e18', title: 'Arka Sıradakiler 18. Bölüm'),
        ],
      );

      expect(
        run.upcoming.map((e) => e.videoId),
        ['e2', 'e3', 'e18', 'e54'],
      );
    });

    test('sezon geçişi: sezon sonundan sonra yeni sezonun 1. bölümü', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Teşkilat 45. Bölüm (Final)'),
        candidates: [
          v('s2e2', title: 'Teşkilat 2. Sezon 2. Bölüm'),
          v('s2e1', title: 'Teşkilat 2. Sezon 1. Bölüm'),
          v('s1e44', title: 'Teşkilat 44. Bölüm'),
        ],
      );

      expect(run.upcoming.map((e) => e.videoId), ['s2e1', 's2e2']);
      expect(run.excludedIds, contains('s1e44'),
          reason: 'geride kalan bölüm kuyruğa girmemeli');
    });

    test('geride kalan bölümler kuyruktan çıkarılır', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 20. Bölüm'),
        candidates: [
          v('e21', title: 'Arka Sıradakiler 21. Bölüm'),
          v('e5', title: 'Arka Sıradakiler 5. Bölüm'),
          v('e19', title: 'Arka Sıradakiler 19. Bölüm'),
        ],
      );

      expect(run.upcoming.map((e) => e.videoId), ['e21']);
      expect(run.excludedIds, {'e5', 'e19'});
    });

    test('aynı bölümün başka kanaldaki yüklemesi kuyruğa girmez', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('kopya', title: 'Arka Sıradakiler 1. Bölüm', uploader: 'Dizi Arşiv'),
          v('e2', title: 'Arka Sıradakiler 2. Bölüm'),
        ],
      );

      expect(run.upcoming.map((e) => e.videoId), ['e2']);
      expect(run.excludedIds, contains('kopya'));
    });

    test('başka kanalın ileri bölümü sıradaki sayılmaz', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('baska', title: 'Arka Sıradakiler 2. Bölüm', uploader: 'Korsan TV'),
        ],
      );

      expect(run.isEmpty, isTrue);
    });

    test('aynı bölümün iki yüklemesinden çok izlenen seçilir', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('az', title: 'Arka Sıradakiler 2. Bölüm', views: 10),
          v('cok', title: 'Arka Sıradakiler 2. Bölüm', views: 9000),
        ],
      );

      expect(run.upcoming.map((e) => e.videoId), ['cok']);
      expect(run.excludedIds, contains('az'));
    });

    test('benzer adlı BAŞKA dizi karışmaz', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('sokaklar', title: 'Arka Sokaklar 2. Bölüm'),
        ],
      );

      expect(run.isEmpty, isTrue);
    });

    test('süresi çok farklı içerik bölüm sayılmaz', () {
      // 2 saatlik bölümün ardından 3 dakikalık bir "2. Bölüm" videosu, bölüm
      // değil tanıtım/klip demektir.
      final run = episodeRunFor(
        seed: v('s', title: 'Kuruluş Osman 1. Bölüm', duration: 7200),
        candidates: [
          v('kisa', title: 'Kuruluş Osman 2. Bölüm', duration: 180),
        ],
      );

      expect(run.isEmpty, isTrue);
    });

    test('dizi olmayan içerikte hiçbir şey değişmez', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Sezen Aksu - Gülümse', duration: 240),
        candidates: [
          v('x', title: 'Kalben - Helal Ettim', duration: 250),
        ],
      );

      expect(run.isEmpty, isTrue);
    });

    test('"Top 10 Şarkı - Bölüm 3" müzik kuyruğunu bozmaz', () {
      // Seed bir şarkı olduğu için bölüm kalıbına uyan aday da alınmamalı.
      final run = episodeRunFor(
        seed: v('s', title: 'Tarkan - Kuzu Kuzu', duration: 240),
        candidates: [
          v('t', title: 'Top 10 Şarkı - Bölüm 3', duration: 300),
        ],
      );

      expect(run.isEmpty, isTrue);
    });

    test('sıradaki bölüm yoksa sessizce boş döner', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 54. Bölüm'),
        candidates: [
          v('e1', title: 'Arka Sıradakiler 1. Bölüm'),
          v('baska', title: 'Yargı 3. Bölüm'),
        ],
      );

      expect(run.isEmpty, isTrue);
      expect(run.excludedIds, isEmpty,
          reason: 'devreye girmediyse hiçbir adayı elememeli');
    });

    test('izlenmiş bölümler atlanır, kalınan yerden devam edilir', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('e2', title: 'Arka Sıradakiler 2. Bölüm'),
          v('e3', title: 'Arka Sıradakiler 3. Bölüm'),
          v('e4', title: 'Arka Sıradakiler 4. Bölüm'),
        ],
        watchedIds: {'e2', 'e3'},
      );

      expect(run.upcoming.map((e) => e.videoId), ['e4']);
    });

    test('hepsi izlenmişse sıra bozulmaz', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          v('e3', title: 'Arka Sıradakiler 3. Bölüm'),
          v('e2', title: 'Arka Sıradakiler 2. Bölüm'),
        ],
        watchedIds: {'e2', 'e3'},
      );

      expect(run.upcoming.map((e) => e.videoId), ['e2', 'e3']);
    });

    test('bölüm sayısı sınırı aşılırsa fazlası kuyruğa girmez', () {
      final run = episodeRunFor(
        seed: v('s', title: 'Arka Sıradakiler 1. Bölüm'),
        candidates: [
          for (var i = 2; i <= 10; i++)
            v('e$i', title: 'Arka Sıradakiler $i. Bölüm'),
        ],
        limit: 3,
      );

      expect(run.upcoming.map((e) => e.videoId), ['e2', 'e3', 'e4']);
      expect(run.excludedIds, hasLength(6));
    });

    test('kanalı bilinmeyen video için bölüm sırası kurulmaz', () {
      final run = episodeRunFor(
        seed: VideoSummary(
          videoId: 's',
          title: 'Arka Sıradakiler 1. Bölüm',
          url: null,
          uploaderName: null,
          durationSeconds: 7200,
          viewCount: 0,
          textualUploadDate: null,
          thumbnailUrl: null,
        ),
        candidates: [v('e2', title: 'Arka Sıradakiler 2. Bölüm')],
      );

      expect(run.isEmpty, isTrue);
    });
  });
}
