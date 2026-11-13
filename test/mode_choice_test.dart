import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:olustiff/core/data/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Gerçekte yaşanan: her yeni video türüne göre yeniden sesli/görüntülü
  // açılıyordu; kullanıcı bunu "kendiliğinden mod değişimi" diye yaşadı.
  test('elle seçilen mod kalıcı: yeniden açılışta da hatırlanır', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore.instance;
    await store.load();
    expect(store.lastAudioOnly, isNull, reason: 'hiç seçilmediyse tahmin kullanılır');

    await store.setLastAudioOnly(false);
    await store.load(); // uygulama yeniden açıldı
    expect(store.lastAudioOnly, isFalse);
  });

  test('"müzikleri sesli başlat" ayarı değişince elle seçim sıfırlanır', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore.instance;
    await store.load();
    await store.setLastAudioOnly(true);

    await store.setMusicAsAudio(false);
    expect(store.lastAudioOnly, isNull,
        reason: 'ayarı bilerek değiştiren onun uygulanmasını bekler');
  });
}
