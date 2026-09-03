import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/features/player/tv_player.dart';

void main() {
  group('televizyonda sarma adımı', () {
    // Tek basış küçük kalmalı: kullanıcı "biraz geri al" derken bir dakika
    // geri gitmek istemiyor.
    test('tek basış 10 saniye', () {
      expect(tvSeekStepSeconds(0), 10);
      expect(tvSeekStepSeconds(1), 10);
      expect(tvSeekStepSeconds(5), 10);
    });

    test('basılı tutuldukça 30 saniyeye ve 1 dakikaya çıkar', () {
      expect(tvSeekStepSeconds(6), 30);
      expect(tvSeekStepSeconds(11), 30);
      expect(tvSeekStepSeconds(12), 60);
      expect(tvSeekStepSeconds(100), 60);
    });

    // Adım büyüdükçe merdiven hızlanmalı ama uçmamalı; basamaklar arası
    // artış oranı iki katı geçmiyor.
    test('merdiven basamakları arasında sıçrama makul', () {
      expect(tvSeekStepSeconds(6) / tvSeekStepSeconds(0), lessThanOrEqualTo(3));
      expect(tvSeekStepSeconds(12) / tvSeekStepSeconds(6), lessThanOrEqualTo(3));
    });
  });
}
