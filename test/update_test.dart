import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/core/update/update_service.dart';

void main() {
  group('isNewer', () {
    test('büyük sürüm yeni kabul edilir', () {
      expect(isNewer('1.1.0', '1.0.0'), isTrue);
      expect(isNewer('2.0.0', '1.9.9'), isTrue);
    });

    test('aynı ve eski sürümler yeni sayılmaz', () {
      expect(isNewer('1.0.0', '1.0.0'), isFalse);
      expect(isNewer('0.9.0', '1.0.0'), isFalse);
    });

    test('sayısal karşılaştırma yapılır, metin değil', () {
      // Metin karşılaştırmasında "1.10" < "1.9" çıkardı.
      expect(isNewer('1.10.0', '1.9.0'), isTrue);
      expect(isNewer('1.9.0', '1.10.0'), isFalse);
    });

    test('eksik parçalar sıfır sayılır', () {
      expect(isNewer('1.1', '1.0.5'), isTrue);
      expect(isNewer('1.0', '1.0.0'), isFalse);
    });
  });
}
