import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/core/playback/similarity.dart';

void main() {
  group('isSameTrack', () {
    test('aynı şarkının sürümleri aynı parça', () {
      expect(isSameTrack('La Câlin (Obiymy)', 'La Calin | TARVYN Remix'), isTrue);
      expect(isSameTrack('La Câlin', 'La Câlin (Slowed + Reverb)'), isTrue);
    });

    test('dizinin farklı bölümleri ayrı parça', () {
      expect(
        isSameTrack('Kuruluş Osman | 57. Bölüm', 'Kuruluş Osman | 60. Bölüm'),
        isFalse,
      );
    });

    test('aynı sanatçının farklı şarkıları ayrı parça', () {
      expect(
        isSameTrack(
          "BTS (방탄소년단) 'Dynamite' Official MV",
          "BTS (방탄소년단) 'Butter' Official MV",
        ),
        isFalse,
      );
    });

    test('kapsama eşitlik sayılmaz', () {
      expect(isSameTrack('Поле', 'Поле мечты'), isFalse);
    });
  });
}
