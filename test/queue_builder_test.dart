import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/core/playback/queue_builder.dart';

VideoSummary v(
  String id,
  String uploader, {
  String? title,
  int duration = 200,
}) =>
    VideoSummary(
      videoId: id,
      title: title ?? 'Video $id',
      url: 'https://www.youtube.com/watch?v=$id',
      uploaderName: uploader,
      durationSeconds: duration,
      viewCount: 0,
      textualUploadDate: null,
      thumbnailUrl: null,
    );

void main() {
  group('QueueBuilder', () {
    test('kuyruk çalan videoyla başlar', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'A'),
        candidates: [v('1', 'B'), v('2', 'C')],
      );

      expect(queue.first.videoId, 'seed');
    });

    test('aynı sanatçı arka arkaya yığılmaz', () {
      // "Selena Gomez" arayınca tüm sonuçlar aynı kanaldan gelir; araya başka
      // sanatçılar serpiştirilmeli.
      final queue = QueueBuilder.build(
        seed: v('seed', 'Selena'),
        candidates: [
          v('1', 'Selena'),
          v('2', 'Selena'),
          v('3', 'Dua'),
          v('4', 'Selena'),
          v('5', 'Ariana'),
        ],
      );

      final uploaders = queue.map((e) => e.uploaderName).toList();
      for (var i = 0; i + 2 < uploaders.length; i++) {
        expect(
          uploaders[i] == uploaders[i + 1] && uploaders[i] == uploaders[i + 2],
          isFalse,
          reason: 'aynı kanaldan üç video üst üste gelmemeli: $uploaders',
        );
      }
    });

    test('tekrar eden videolar elenir', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'A'),
        candidates: [v('1', 'B'), v('1', 'B'), v('seed', 'A')],
      );

      final ids = queue.map((e) => e.videoId).toList();
      expect(ids, ids.toSet().toList(), reason: 'kuyrukta tekrar olmamalı');
    });

    test('farklı dildeki içerik kuyruğa alınmaz', () {
      // Türkçe/İngilizce dinlerken araya Hintçe veya Arapça şarkı girmemeli.
      final queue = QueueBuilder.build(
        seed: v('seed', 'Sezen Aksu', title: 'Sezen Aksu - Gulumse'),
        candidates: [
          v('1', 'Dhanda Nyoliwala', title: 'ZALIM WADERA | Saraiki गीत'),
          v('2', 'Kalben', title: 'Kalben - Helal Ettim'),
        ],
      );

      final ids = queue.map((e) => e.videoId).toList();
      expect(ids, contains('2'), reason: 'aynı dildeki içerik kalmalı');
      expect(ids, isNot(contains('1')),
          reason: 'farklı yazı sistemindeki içerik elenmeli');
    });

    test('süresi çok farklı içerik elenir', () {
      // 3 dakikalık şarkının ardından 2 saatlik mix akışı bozar.
      final queue = QueueBuilder.build(
        seed: v('seed', 'Artist', title: 'Artist - Song', duration: 200),
        candidates: [
          v('mix', 'Some Channel', title: 'Best Mix 2024', duration: 7200),
        ],
      );

      expect(queue.map((e) => e.videoId), isNot(contains('mix')));
    });

    test('en benzer aday öne alınır', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'Tarkan', title: 'Tarkan - Kuzu Kuzu'),
        candidates: [
          v('uzak', 'Baska Kanal', title: 'Doga Belgeseli'),
          v('yakin', 'Tarkan', title: 'Tarkan - Simarik'),
        ],
      );

      expect(queue[1].videoId, 'yakin',
          reason: 'aynı sanatçı ve tarz önce gelmeli');
      expect(queue.map((e) => e.videoId), contains('uzak'),
          reason: 'benzerliği düşük ama aynı dildeki içerik yine de kuyrukta');
    });

    test('aday yoksa yalnızca çalan video döner', () {
      final queue = QueueBuilder.build(seed: v('seed', 'A'), candidates: []);
      expect(queue, hasLength(1));
    });

    test('tüm adaylar aynı kanaldansa yine de kuyruğa alınır', () {
      // Çeşitlilik tercih edilir ama mümkün değilse içerik atılmamalı.
      final queue = QueueBuilder.build(
        seed: v('seed', 'A'),
        candidates: [v('1', 'A'), v('2', 'A')],
      );

      expect(queue, hasLength(3));
    });
  });

  group('QueueBuilder — dizi bölümleri', () {
    test('sıradaki bölüm kuyruğun başına gelir', () {
      // Kullanıcının şikâyeti: "1. Bölüm"den sonra "54. Bölüm" çalıyordu.
      final queue = QueueBuilder.build(
        seed: v('seed', 'Kanal D',
            title: 'Arka Sıradakiler 1. Bölüm', duration: 7200),
        candidates: [
          v('e54', 'Kanal D',
              title: 'Arka Sıradakiler 54. Bölüm', duration: 7200),
          v('e18', 'Kanal D',
              title: 'Arka Sıradakiler 18. Bölüm', duration: 7200),
          v('e2', 'Kanal D',
              title: 'Arka Sıradakiler 2. Bölüm', duration: 7200),
        ],
        watchedIds: const {},
      );

      expect(queue[1].videoId, 'e2');
      expect(queue.map((e) => e.videoId), ['seed', 'e2', 'e18', 'e54'],
          reason: 'bölümler numara sırasına dizilmeli');
    });

    test('geride kalan bölümler kuyruğa hiç girmez', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'Kanal D',
            title: 'Arka Sıradakiler 20. Bölüm', duration: 7200),
        candidates: [
          v('e21', 'Kanal D',
              title: 'Arka Sıradakiler 21. Bölüm', duration: 7200),
          v('e3', 'Kanal D',
              title: 'Arka Sıradakiler 3. Bölüm', duration: 7200),
          v('baska', 'Kanal D', title: 'Doğa Belgeseli', duration: 7200),
        ],
        watchedIds: const {},
      );

      expect(queue.map((e) => e.videoId), ['seed', 'e21', 'baska']);
    });

    test('dizi olmayan içerikte benzerlik sırası korunur', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'Tarkan', title: 'Tarkan - Kuzu Kuzu'),
        candidates: [
          v('uzak', 'Baska Kanal', title: 'Doga Belgeseli'),
          v('yakin', 'Tarkan', title: 'Tarkan - Simarik'),
        ],
        watchedIds: const {},
      );

      expect(queue[1].videoId, 'yakin');
    });

    test('bölümlerden sonra kuyruk başka kanalla devam eder', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'Kanal D',
            title: 'Arka Sıradakiler 1. Bölüm', duration: 7200),
        candidates: [
          v('e2', 'Kanal D',
              title: 'Arka Sıradakiler 2. Bölüm', duration: 7200),
          v('ayni', 'Kanal D', title: 'Kanal D Haber', duration: 7200),
          v('farkli', 'Show TV', title: 'Haber Bülteni', duration: 7200),
        ],
        watchedIds: const {},
      );

      expect(queue[1].videoId, 'e2');
      expect(queue[2].uploaderName, 'Show TV',
          reason: 'bölüm dizisi bitince aynı kanalda yığılmamalı');
    });
  });

  group('QueueBuilder.extend', () {
    // Kuyruk bitince oynatma duruyordu; sona yaklaşınca öneriyle uzuyor.
    test('kuyrukta olmayan adaylar sona eklenir', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A'),
        existing: [v('calan', 'A'), v('1', 'B')],
        candidates: [v('1', 'B'), v('2', 'C'), v('3', 'D')],
      );
      expect(added.map((e) => e.videoId), ['2', '3']);
    });

    test('çalan video yeniden eklenmez', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A'),
        existing: const [],
        candidates: [v('calan', 'A'), v('2', 'B')],
      );
      expect(added.map((e) => e.videoId), ['2']);
    });

    test('aday kalmadıysa boş döner ve kuyruk uzamaz', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A'),
        existing: [v('1', 'B')],
        candidates: [v('1', 'B')],
      );
      expect(added, isEmpty);
    });

    test('istenen sayıdan fazlası eklenmez', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A'),
        existing: const [],
        candidates: [for (var i = 0; i < 30; i++) v('$i', 'K$i')],
        limit: 4,
      );
      expect(added, hasLength(4));
    });

    // Benzerlik eşiğini geçemeyen (başka yazı sistemi) adaylar kuyruğa
    // girmemeli — uzatma, kuyruğun tarzını bozmanın yolu olmamalı.
    test('alakasız aday eklenmez', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A', title: 'Sezen Aksu şarkısı'),
        existing: const [],
        candidates: [v('yabanci', 'B', title: '中文歌曲 完整版', duration: 4000)],
      );
      expect(added, isEmpty);
    });

    // Kuyruğun son videosuyla aynı kanaldan üst üste yığılmamalı.
    test('aynı kanal üst üste yığılmaz', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A'),
        existing: [v('son', 'A')],
        candidates: [v('1', 'A'), v('2', 'A'), v('3', 'B')],
      );
      // Kuyruğun sonu zaten A; ikinci sırada A gelemez.
      expect(added.first.uploaderName, 'A');
      expect(added[1].uploaderName, 'B');
    });
  });

  group('aynı parçanın sürümleri', () {
    // Gerçek şikâyet buydu: bir şarkı arandığında kuyruk baştan sona o
    // şarkının remiks/hızlandırılmış/kapak sürümleriyle doluyordu. Sebebi
    // benzerlik puanının ters çalışması: remiks, şarkıya en çok benzeyen şey.
    test('remiks ve benzeri sürümler kuyruğa girmez', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'Serhat Durmus', title: 'Serhat Durmus - La Câlin'),
        candidates: [
          v('1', 'Serhat Durmus', title: 'Serhat Durmus - La Câlin (Remix)'),
          v('2', 'Baska Kanal', title: 'La Câlin - Serhat Durmus (Slowed + Reverb)'),
          v('3', 'Serhat Durmus', title: 'Serhat Durmus - Elsewhere'),
        ],
      );
      expect(queue.map((e) => e.videoId), ['seed', '3']);
    });

    test('aynı sanatçının başka şarkısı kuyrukta kalır', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'RAIKAHO', title: 'RAIKAHO - Поле'),
        candidates: [v('1', 'RAIKAHO', title: 'RAIKAHO - Дверцы')],
      );
      expect(queue.map((e) => e.videoId), ['seed', '1']);
    });

    // Kapsama ölçütü kullanılsaydı "Поле мечты" yanlışlıkla elenirdi.
    test('başlığı uzatılmış FARKLI şarkı elenmez', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'RAIKAHO', title: 'RAIKAHO - Поле'),
        candidates: [v('1', 'RAIKAHO', title: 'RAIKAHO - Поле мечты')],
      );
      expect(queue.map((e) => e.videoId), ['seed', '1']);
    });

    test('iki farklı remiks de tek tek elenir', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'A', title: 'Sanatci - Sarki'),
        candidates: [
          v('1', 'A', title: 'Sanatci - Sarki (Remix)'),
          v('2', 'B', title: 'Sanatci - Sarki (Nightcore)'),
        ],
      );
      expect(queue.map((e) => e.videoId), ['seed']);
    });

    // ÇOK ÖNEMLİ: bölüm numaraları çekirdekte korunuyor. Korunmasaydı tüm
    // bölümler "aynı parça" sayılır ve dizi kuyruğu tek bölüme inerdi.
    test('dizi bölümleri birbirini elemez', () {
      final queue = QueueBuilder.build(
        seed: v('seed', 'Dizi', title: 'Arka Sıradakiler 57. Bölüm'),
        candidates: [
          v('1', 'Dizi', title: 'Arka Sıradakiler 58. Bölüm'),
          v('2', 'Dizi', title: 'Arka Sıradakiler 59. Bölüm'),
        ],
        watchedIds: const {},
      );
      expect(queue.map((e) => e.videoId), containsAll(['1', '2']));
    });

    test('uzatmada da aynı sürümler sızmaz', () {
      final added = QueueBuilder.extend(
        current: v('calan', 'A', title: 'Sanatci - Sarki'),
        existing: [v('calan', 'A', title: 'Sanatci - Sarki')],
        candidates: [
          v('1', 'A', title: 'Sanatci - Sarki (Official Audio)'),
          v('2', 'A', title: 'Sanatci - Baska Sarki'),
        ],
      );
      expect(added.map((e) => e.videoId), ['2']);
    });
  });
}
