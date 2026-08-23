import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/playback/playback_client.dart';
import '../../core/playback/ui_channel.dart';
import 'quality_menu.dart';
import 'video_surface.dart';

/// Videonun ekrana nasıl sığdırılacağı.
enum VideoFit {
  /// Tamamı görünür, kenarlarda siyah bant olabilir.
  contain,

  /// Ekranı doldurur, taşan kısım kırpılır.
  cover,
}

/// Dokunmatik kontrol katmanıyla birlikte video görüntüsü.
///
/// Kontroller video üstünde durur ve birkaç saniye sonra kendiliğinden
/// gizlenir; ekrana dokununca geri gelir. Çift dokunuş 10 saniye sarar
/// (sol/sağ), tam ekran butonu yatay moda geçirir.
class VideoPlayerView extends StatefulWidget {
  const VideoPlayerView({
    super.key,
    required this.state,
    required this.playback,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.onEnterPip,
    this.posterUrl,
  });

  final PlaybackState state;
  final PlaybackClient playback;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback? onEnterPip;

  /// İlk kare gelene kadar gösterilecek kapak.
  final String? posterUrl;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  static const _autoHideDelay = Duration(seconds: 3);

  bool _controlsVisible = true;
  bool _locked = false;
  VideoFit _fit = VideoFit.contain;
  Timer? _hideTimer;

  /// Çift dokunuş geri bildirimi ("10 sn ileri/geri") için.
  String? _seekHint;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    // Duraklatılmışken kontroller açık kalsın; kullanıcı bir şey yapmak üzere.
    if (!widget.state.playWhenReady) return;
    _hideTimer = Timer(_autoHideDelay, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _seekBy(Duration offset) {
    final target = widget.state.position + offset;
    widget.playback
        .seekTo(target < Duration.zero ? Duration.zero : target);

    setState(() {
      _seekHint = offset.isNegative
          ? '${offset.inSeconds.abs()} sn geri'
          : '${offset.inSeconds} sn ileri';
    });
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekHint = null);
    });
  }

  void _onDoubleTapDown(TapDownDetails details, BoxConstraints constraints) {
    if (_locked) return;
    final isLeft = details.localPosition.dx < constraints.maxWidth / 2;
    _seekBy(Duration(seconds: isLeft ? -10 : 10));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTap: _toggleControls,
          onDoubleTapDown: (d) => _onDoubleTapDown(d, constraints),
          // Çift dokunuş algılansın diye boş kalsa da gerekli.
          onDoubleTap: () {},
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildVideo(),
                if (_seekHint != null) _SeekHint(text: _seekHint!),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideo() {
    final state = widget.state;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Yüzey ağaçta SABİT tutulur ve yapısı hiç değişmez.
        // Daha önce sığdır/doldur ve yükleme durumlarında farklı sarmalayıcılar
        // kullanılıyordu; Flutter bunu farklı bir widget sayıp yüzeyi yok edip
        // yeniden kuruyor, native video yüzeyi kopuyor ve görüntü hiç
        // gelmiyordu. Tek yapı + değişen `fit` bunu önlüyor.
        ClipRect(
          child: FittedBox(
            fit: _fit == VideoFit.contain ? BoxFit.contain : BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: state.aspectRatio * 1000,
              height: 1000,
              child: const VideoSurface(),
            ),
          ),
        ),

        // İlk kare gelene kadar yüzeyde ÖNCEKİ videonun karesi durur;
        // onun yerine yeni videonun kapağı gösterilir.
        if (!state.hasVideoFrame) ...[
          if (widget.posterUrl != null)
            Image.network(widget.posterUrl!, fit: BoxFit.cover),
          Container(color: Colors.black.withValues(alpha: 0.55)),
        ],

        // Yükleme göstergesi görüntünün üstünde; oynat/duraklat butonunda
        // ayrıca dönmesi kafa karıştırıyordu.
        if (!state.hasVideoFrame || state.isBuffering)
          const Center(
            child: SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControls() {
    if (_locked) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _RoundButton(
            icon: Icons.lock_outline,
            tooltip: 'Kontrolleri aç',
            onPressed: () => setState(() => _locked = false),
          ),
        ),
      );
    }

    final state = widget.state;

    return Container(
      color: Colors.black26,
      child: Stack(
        children: [
          // Üst sıra: kilit, en-boy, PiP, tam ekran
          Positioned(
            top: 4,
            right: 4,
            child: Row(
              children: [
                _RoundButton(
                  icon: Icons.lock_open_outlined,
                  tooltip: 'Kontrolleri kilitle',
                  onPressed: () => setState(() => _locked = true),
                ),
                // Kalite, tam ekrandan çıkmadan değiştirilebilsin.
                _RoundButton(
                  icon: Icons.high_quality_outlined,
                  tooltip: 'Kalite',
                  onPressed: () => showQualityMenu(context),
                ),
                _RoundButton(
                  icon: _fit == VideoFit.contain
                      ? Icons.fit_screen_outlined
                      : Icons.crop_free,
                  tooltip: _fit == VideoFit.contain ? 'Ekranı doldur' : 'Sığdır',
                  onPressed: () => setState(() {
                    _fit = _fit == VideoFit.contain
                        ? VideoFit.cover
                        : VideoFit.contain;
                  }),
                ),
                if (widget.onEnterPip != null)
                  _RoundButton(
                    icon: Icons.picture_in_picture_alt_outlined,
                    tooltip: 'Küçük pencere',
                    onPressed: widget.onEnterPip!,
                  ),
              ],
            ),
          ),

          // Orta: oynat/duraklat. Yükleme göstergesi görüntünün üstünde
          // olduğu için burada ayrıca dönmez.
          Center(
            child: _RoundButton(
              icon: state.playWhenReady ? Icons.pause : Icons.play_arrow,
              size: 44,
              onPressed: () {
                state.playWhenReady
                    ? widget.playback.pause()
                    : widget.playback.resume();
                _scheduleHide();
              },
            ),
          ),

          // Alt sıra: konum, ilerleme çubuğu, tam ekran
          Positioned(
            left: 8,
            right: 8,
            bottom: 4,
            child: _BottomBar(
              state: state,
              playback: widget.playback,
              isFullscreen: widget.isFullscreen,
              onToggleFullscreen: widget.onToggleFullscreen,
              onInteraction: _scheduleHide,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.playback,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    required this.onInteraction,
  });

  final PlaybackState state;
  final PlaybackClient playback;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onInteraction;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final duration = state.duration;
    final isLive = duration == null;
    final maxMs = (duration ?? Duration.zero).inMilliseconds.toDouble();
    final positionMs = state.position.inMilliseconds
        .clamp(0, (duration ?? Duration.zero).inMilliseconds);

    return Row(
      children: [
        Text(
          isLive ? 'CANLI' : _fmt(state.position),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        Expanded(
          child: isLive
              ? const SizedBox.shrink()
              : SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: maxMs == 0 ? 0 : positionMs.toDouble(),
                    max: maxMs == 0 ? 1 : maxMs,
                    onChanged: maxMs == 0
                        ? null
                        : (v) {
                            playback
                                .seekTo(Duration(milliseconds: v.toInt()));
                            onInteraction();
                          },
                  ),
                ),
        ),
        if (!isLive)
          Text(
            _fmt(duration),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        _RoundButton(
          icon: isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: isFullscreen ? 'Tam ekrandan çık' : 'Tam ekran',
          onPressed: () {
            onToggleFullscreen();
            onInteraction();
          },
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 22,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: size),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

/// Çift dokunuş sonrası kısa süre görünen "10 sn ileri/geri" balonu.
class _SeekHint extends StatelessWidget {
  const _SeekHint({required this.text});

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

/// Tam ekran video sayfası: yatay yönlendirme ve gizli sistem çubukları.
class FullscreenPlayerPage extends StatefulWidget {
  const FullscreenPlayerPage({
    super.key,
    required this.playback,
  });

  final PlaybackClient playback;

  @override
  State<FullscreenPlayerPage> createState() => _FullscreenPlayerPageState();
}

class _FullscreenPlayerPageState extends State<FullscreenPlayerPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StreamBuilder<PlaybackState>(
        stream: widget.playback.stateStream,
        builder: (context, snapshot) {
          final state = snapshot.data ?? const PlaybackState();
          return VideoPlayerView(
            state: state,
            playback: widget.playback,
            isFullscreen: true,
            onToggleFullscreen: () => Navigator.of(context).pop(),
            onEnterPip: () => UiChannel.instance.enterPictureInPicture(),
          );
        },
      ),
    );
  }
}
