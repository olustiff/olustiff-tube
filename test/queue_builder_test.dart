import 'package:flutter_test/flutter_test.dart';

import 'package:akis/core/extraction/models.dart';
import 'package:akis/core/playback/queue_builder.dart';

VideoSummary v(String id, String uploader) => VideoSummary(
      videoId: id,
      title: 'Video $id',
      url: 'https://www.youtube.com/watch?v=$id',
      uploaderName: uploader,
      durationSeconds: 100,
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
