import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/features/player/tv_player.dart';

void main() {
  group('televizyonda sarma adımı', () {
    test('tek basış 10 saniye', () {
      expect(tvSeekStepSeconds(0), 10);
    });

    test('kısa süre basılı tutmak adımı büyütmez', () {
      // Kullanıcı düzeltme yaparken tuşa iki kez basıyor olabilir; adımın
      // hemen büyümesi hedefi aşmasına yol açardı.
      expect(tvSeekStepSeconds(1), 10);
      expect(tvSeekStepSeconds(5), 10);
    });

    test('basılı tutuldukça 20 ve 30 saniyeye çıkar', () {
      expect(tvSeekStepSeconds(6), 20);
      expect(tvSeekStepSeconds(13), 20);
      expect(tvSeekStepSeconds(14), 30);
      expect(tvSeekStepSeconds(100), 30);
    });
  });
}
