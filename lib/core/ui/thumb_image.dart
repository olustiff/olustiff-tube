import 'package:flutter/widgets.dart';

/// Küçük resim: ekranda kapladığı boyutta belleğe açılır.
///
/// ## Neden
///
/// `Image.network` resmi ASIL çözünürlüğünde açıyor. YouTube küçük resimleri
/// 1280×720'ye kadar çıkıyor; her biri bellekte ~3.7 MB tutuyor, oysa
/// listede 128 piksellik bir kutuya çiziliyor. 1.4 GB belleği olan bir TCL
/// televizyonda uygulama en çok belleği kullanan program olmuştu (~120 MB)
/// ve TV ara ara donuyordu (23 Kas 2026). Ekran boyutunda açmak her resmi
/// onda birine kadar küçültüyor.
class ThumbImage extends StatelessWidget {
  const ThumbImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.errorBuilder,
  });

  final String url;
  final BoxFit fit;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      // Genişlik bilinmiyorsa (sınırsız alan) eski davranış.
      final cacheWidth = width.isFinite && width > 0
          ? (width * MediaQuery.devicePixelRatioOf(context)).ceil()
          : null;
      return Image.network(
        url,
        fit: fit,
        cacheWidth: cacheWidth,
        errorBuilder: errorBuilder,
      );
    });
  }
}

/// Resim önbelleğinin üst sınırı.
///
/// Flutter'ın varsayılanı 100 MB: düşük bellekli televizyonlarda uygulama
/// gezindikçe büyüyüp orada kalıyordu. Ekranda görünenler zaten canlı
/// tutuluyor; sınır yalnızca ekrandan çıkmış eski resimleri etkiliyor.
void limitImageCache({required bool lowMemory}) {
  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSizeBytes = (lowMemory ? 24 : 48) << 20;
  cache.maximumSize = lowMemory ? 150 : 300;
}
