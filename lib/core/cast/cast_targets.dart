import 'cast_protocol.dart' show CastDevice;
import 'youtube_cast_protocol.dart' show YouTubeCastDevice;

/// Kullanıcının listede gördüğü TEK bir televizyon.
///
/// Neden ayrı bir tür: iki keşif ayrı çalışıyor ve aynı televizyonu ayrı
/// türlerle buluyor — biri "üstünde oLusTifF var", diğeri "kendi YouTube'u
/// var" diyor. İkisi de doğru ve çoğu evde ikisi de AYNI televizyon için
/// doğru. Listeye ham hâlleriyle konduğunda kullanıcı aynı adı taşıyan iki
/// satır görüyor ve hangisine bastığını ayırt edemiyor; gerçek cihazda
/// yaşandı ve yavaş olan yol seçildiğinde video takılıyordu.
class CastTarget {
  const CastTarget({required this.name, required this.host, this.youtube, this.ours});

  final String name;

  /// Televizyonun adresi; iki keşfi eşleştiren anahtar da bu.
  final String host;

  /// Televizyonun kendi YouTube uygulaması bulunduysa.
  final YouTubeCastDevice? youtube;

  /// Televizyonda oLusTifF alıcısı çalışıyorsa.
  final CastDevice? ours;

  /// İki yolu da sunan televizyonlarda kullanıcıya seçenek gösteriliyor.
  bool get hasBoth => youtube != null && ours != null;
}

/// İki keşfin sonucunu tek listeye indirir.
///
/// Eşleştirme ADRESE göre yapılıyor, ada göre değil: iki televizyonun aynı adı
/// taşıması mümkün ("Android TV" fabrika ayarı), ama aynı anda aynı adreste
/// olmaları mümkün değil.
///
/// Sıralama: kendi YouTube'u olan televizyonlar önce geliyor. Sebebi ölçüm —
/// o yolda videoyu televizyonun kendi oynatıcısı çözüyor ve gerçek cihazda
/// 30 saniye boyunca hiç takılmadan, tam 1.00x hızda oynattı; bizim alıcımız
/// aynı videoda birkaç saniyede bir duraklıyordu.
List<CastTarget> mergeCastTargets(
  List<YouTubeCastDevice> youtube,
  List<CastDevice> ours,
) {
  final byHost = <String, CastTarget>{};

  for (final device in youtube) {
    byHost[device.host] = CastTarget(
      name: device.name,
      host: device.host,
      youtube: device,
    );
  }

  for (final device in ours) {
    final existing = byHost[device.host];
    byHost[device.host] = CastTarget(
      // Ad, önce bulunandan korunuyor: ikisi de aynı televizyonu adlandırıyor
      // ve listede satırın adının arama tekrarları arasında oynaması
      // kullanıcıya farklı bir cihaz gibi görünürdü.
      name: existing?.name ?? device.name,
      host: device.host,
      youtube: existing?.youtube,
      ours: device,
    );
  }

  final targets = byHost.values.toList();
  targets.sort((a, b) {
    final byPath = (b.youtube != null ? 1 : 0) - (a.youtube != null ? 1 : 0);
    // Eşitlikte ada göre: sıralamanın her aramada aynı çıkması, listenin
    // gözde "oynamaması" için gerekiyor.
    return byPath != 0 ? byPath : a.name.compareTo(b.name);
  });
  return targets;
}
