import 'package:flutter/material.dart';

/// Uygulama çubuğundaki marka: solda logo işareti, yanında logonun kendi
/// tipografisiyle yazılmış adı.
///
/// Metin olarak yazmak yerine logodan kesilen görsel kullanılıyor; böylece
/// yazı tipi ve kırmızı "T" logoyla birebir aynı kalıyor. Görsel bir sebeple
/// yüklenemezse düz yazıya düşülür — başlık asla kaybolmaz.
class AppTitle extends StatelessWidget {
  const AppTitle({super.key});

  static const _fallback = Text(
    'oLusTifF',
    style: TextStyle(fontWeight: FontWeight.w800, fontStyle: FontStyle.italic),
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/logo_mark.png',
          height: 30,
          errorBuilder: (context, error, stack) =>
              const Icon(Icons.play_circle_fill, size: 26),
        ),
        const SizedBox(width: 10),
        // Yükseklik işaretten küçük: yazı, işaretle optik olarak dengelensin.
        Image.asset(
          'assets/logo_wordmark.png',
          height: 17,
          errorBuilder: (context, error, stack) => _fallback,
        ),
      ],
    );
  }
}
