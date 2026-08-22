import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native ExoPlayer video yüzeyini Flutter ağacına gömer.
///
/// Bu widget yalnızca bir görüntü penceresidir; ağaçtan kaldırıldığında
/// oynatma DURMAZ, sadece yüzey ayrılır. Böylece video ekranından çıkıldığında
/// ses arka planda akmaya devam eder.
class VideoSurface extends StatelessWidget {
  const VideoSurface({super.key});

  static const _viewType = 'akis/player_view';

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: AndroidView(
        viewType: _viewType,
        creationParamsCodec: const StandardMessageCodec(),
        // Video yüzeyinin dokunmatik olayları tüketmesine gerek yok;
        // kontroller Flutter tarafında çiziliyor.
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
    );
  }
}
