import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/playback/playback_client.dart';
import '../../core/i18n/lang.dart';

/// Kaç saniye sarılacağı. YouTube'un alışılmış davranışı.
const kDoubleTapSeekSeconds = 10;

/// Sarma miktarını kısa süre ekranda gösterir.
class SeekHint extends StatelessWidget {
  const SeekHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

/// Sol/sağ yarısına çift dokunarak sarma.
///
/// Sesli modda kullanılır: orada video yüzeyi hiç oluşturulmadığı için
/// [VideoPlayerView]'ın kendi çift dokunuşu devrede olmaz, ama kullanıcı
/// müzik dinlerken de sarabilmeli.
class DoubleTapSeek extends StatefulWidget {
  const DoubleTapSeek({
    super.key,
    required this.child,
    required this.state,
    required this.playback,
    this.enabled = true,
    this.onTap,
  });

  final Widget child;
  final PlaybackState state;
  final PlaybackClient playback;

  /// Canlı yayında sarma anlamsız olduğu için kapatılabilir.
  final bool enabled;

  /// Tek dokunuş davranışı (varsa).
  final VoidCallback? onTap;

  @override
  State<DoubleTapSeek> createState() => _DoubleTapSeekState();
}

class _DoubleTapSeekState extends State<DoubleTapSeek> {
  String? _hint;
  Timer? _hintTimer;

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  void _seekBy(Duration offset) {
    final target = widget.state.position + offset;
    widget.playback.seekTo(target < Duration.zero ? Duration.zero : target);

    setState(() {
      _hint = offset.isNegative
          ? tr('${offset.inSeconds.abs()} sn geri', '${offset.inSeconds.abs()}s back')
          : tr('${offset.inSeconds} sn ileri', '${offset.inSeconds}s forward');
    });
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTap: widget.onTap,
          onDoubleTapDown: (d) {
            if (!widget.enabled) return;
            final isLeft = d.localPosition.dx < constraints.maxWidth / 2;
            _seekBy(Duration(
              seconds: isLeft ? -kDoubleTapSeekSeconds : kDoubleTapSeekSeconds,
            ));
          },
          // Çift dokunuş algılansın diye boş kalsa da gerekli.
          onDoubleTap: () {},
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_hint != null) SeekHint(text: _hint!),
            ],
          ),
        );
      },
    );
  }
}
