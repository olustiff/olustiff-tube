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
}
