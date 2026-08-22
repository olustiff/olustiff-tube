import 'package:flutter/material.dart';

import '../../core/playback/playback_client.dart';

/// Native ExoPlayer'ın video çıktısını gösteren yüzey.
///
/// Flutter'ın `Texture` katmanını kullanır (PlatformView değil): gömülü
/// PlayerView bazı gerçek cihazlarda siyah kare olarak çiziliyordu.
///
/// Widget ağaçtan kaldırıldığında oynatma DURMAZ — yalnızca görüntü ayrılır,
/// ses arka planda akmaya devam eder.
class VideoSurface extends StatefulWidget {
  const VideoSurface({super.key});

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  final _playback = PlaybackClient.shared;
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  Future<void> _attach() async {
    final id = await _playback.attachVideoTexture();
    if (mounted) setState(() => _textureId = id);
  }

  @override
  void dispose() {
    // Yalnızca görüntü ayrılır; player'a dokunulmaz.
    _playback.detachVideoTexture();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    return ColoredBox(
      color: Colors.black,
      child: id == null
          ? const Center(child: CircularProgressIndicator())
          : Texture(textureId: id),
    );
  }
}
