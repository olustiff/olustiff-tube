import 'package:flutter/foundation.dart';

import '../playback/ui_channel.dart';

/// Uygulamanın televizyonda mı çalıştığı.
///
/// Telefon ve televizyon aynı APK'yı kullanıyor — ayrı sürüm yayınlamak
/// gereksiz, çünkü fark yalnızca arayüzde. Televizyonda kumandayla
/// geziliyor: odaklanan öğe belirgin bir çerçeveyle işaretlenmeli ve
/// dokunmaya özel hareketlerin karşılığı tuşlarla verilmeli.
class TvMode {
  TvMode._();

  static final ValueNotifier<bool> isTv = ValueNotifier(false);

  /// Ekranın tamamı kullanılsın mı (kenar payı olmadan).
  ///
  /// Televizyonların bir kısmı görüntünün kenarlarını kırptığı için arayüz
  /// ekranlarında kenardan pay bırakılıyor. Ama VİDEO tam ekranı doldurmalı:
  /// oynatıcıda o pay siyah çerçeve olarak görünüyor.
  static final ValueNotifier<bool> fullBleed = ValueNotifier(false);

  /// Açılışta bir kez sorulur; cihaz türü çalışma sırasında değişmez.
  static Future<void> detect() async {
    try {
      isTv.value = await UiChannel.instance.isTelevision();
    } catch (_) {
      // Algılanamadıysa dokunmatik varsayımı güvenli taraftır.
      isTv.value = false;
    }
  }
}
