import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/features/player/tv_player.dart';

void main() {
  group('televizyon kalite etiketi', () {
    // Gerçek televizyonda görüldü: "Otomatik" seçiliyken ekranda
    // "Otomatik • Otomatik" yazıyor, o an kaç p oynadığı hiç görünmüyordu.
    test('otomatik seçiliyken oynatılan çözünürlük yazılır', () {
      expect(qualityDetail(1080, 'Otomatik'), '1080p');
    });

    test('çözünürlük bilinmiyorsa Otomatik kelimesi tekrarlanmaz', () {
      expect(qualityDetail(0, 'Otomatik'), isNull);
    });

    test('sabit kalitede etiket korunur', () {
      expect(qualityDetail(0, 'Sadece ses'), 'Sadece ses');
    });

    // Oynatıcının bildirdiği değer, ayarın söylediğinden üstün: kullanıcı
    // 1080p seçmiş olsa da video 720p sunuyorsa ekranda 720p yazmalı.
    test('oynatıcının bildirdiği değer ayarın önüne geçer', () {
      expect(qualityDetail(720, '1080p'), '720p');
    });
  });
}
