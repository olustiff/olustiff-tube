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

  group('sürüm dosyası seçimi', () {
    Map<String, dynamic> asset(String name) => {'name': name, 'size': 1};

    final assets = [
      asset('olustiff.apk'),
      asset('olustiff-arm64.apk'),
      asset('olustiff-arm32.apk'),
    ];

    test('cihazın mimarisine uyan dosya seçilir', () {
      expect(pickApkAsset(assets, 'arm64')['name'], 'olustiff-arm64.apk');
      expect(pickApkAsset(assets, 'arm32')['name'], 'olustiff-arm32.apk');
    });

    test('uyan dosya yoksa ortak dosyaya düşülür', () {
      // x64 yayınlanmamış: yanlış mimarili APK kurdurmaktansa hepsini
      // taşıyan ortak dosya indirilir.
      expect(pickApkAsset(assets, 'x64')['name'], 'olustiff.apk');
      expect(pickApkAsset(assets, null)['name'], 'olustiff.apk');
    });

    test('mimariye özel dosya ortak dosya sanılmaz', () {
      final onlyAbi = [asset('olustiff-arm64.apk')];
      // Ortak dosya yokken elde olanla devam edilir.
      expect(pickApkAsset(onlyAbi, 'x64')['name'], 'olustiff-arm64.apk');
    });

    test('APK olmayan dosyalar yok sayılır', () {
      expect(pickApkAsset([asset('notlar.txt')], 'arm64'), isEmpty);
    });
  });
}
