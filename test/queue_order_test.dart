import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/core/playback/queue_order.dart';

void main() {
  group('sıradakiler', () {
    test('karıştırma kapalıyken kuyruk sırası korunur', () {
      expect(
        upcomingQueueIndexes(order: const [], current: 1, queueLength: 5),
        [2, 3, 4],
      );
    });

    // Asıl hata buydu: karışık çalarken arayüz kuyruğun ham sırasını
    // gösteriyordu, yani çalmayacak videoları "sıradaki" diye yazıyordu.
    test('karıştırma açıkken gerçek çalma sırası döner', () {
      expect(
        upcomingQueueIndexes(
          order: const [2, 0, 4, 1, 3],
          current: 0,
          queueLength: 5,
        ),
        [4, 1, 3],
      );
    });

    test('sıranın sonundaysa boş döner', () {
      expect(
        upcomingQueueIndexes(order: const [2, 0, 1], current: 1, queueLength: 3),
        isEmpty,
      );
    });

    test('boş kuyrukta boş döner', () {
      expect(
        upcomingQueueIndexes(order: const [], current: -1, queueLength: 0),
        isEmpty,
      );
    });

    // Kuyruk ile sıra bir an için uyuşmayabiliyor (kuyruk yeni uzatıldı,
    // sıra henüz bildirilmedi). O anda boş liste göstermek yanlış olurdu.
    test('çalan sırada yoksa tüm sıra gösterilir', () {
      expect(
        upcomingQueueIndexes(order: const [2, 0, 1], current: 7, queueLength: 3),
        [2, 0, 1],
      );
    });

    test('aralık dışı ve tekrar eden indeksler ayıklanır', () {
      expect(
        upcomingQueueIndexes(
          order: const [0, 9, -1, 1, 1, 2],
          current: 0,
          queueLength: 3,
        ),
        [1, 2],
      );
    });
  });
}
