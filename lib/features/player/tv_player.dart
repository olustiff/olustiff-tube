import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/extraction/models.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/playback_coordinator.dart';
import 'video_surface.dart';

/// Televizyonda oynatma ekranı: video tam ekran, kontroller kumandayla.
///
/// Neden ayrı bir ekran: telefondaki [VideoPlayerView] dokunmaya göre
/// kurulmuş — düğmeler parmakla ulaşılabilecek yerlerde ve gezinme Flutter'ın
/// odak dolaşımına bırakılmış. Televizyonda bu iki varsayım da tutmuyordu:
/// kumandanın ok tuşları odağı beklenmedik düğmelere taşıyor, OK tuşu bazen
/// hiçbir şeye gitmiyordu.
///
/// Bu yüzden burada Flutter'ın odak dolaşımı HİÇ kullanılmıyor. Ağaçta
/// odaklanabilir tek bir düğüm var (kök [Focus]); hangi öğenin seçili olduğu
/// [_row] / [_buttonIndex] / [_panelIndex] ile bu sınıfta tutuluyor ve seçim
/// çerçevesi elle çiziliyor. Böylece her tuşun nereye gideceği kesin.
///
/// Tuş haritası:
/// - OK: kontroller kapalıysa açar (seçim oynat/duraklat'ta), açıksa seçili
///   öğeyi çalıştırır.
/// - Sol/Sağ: 10 sn sarma (kontroller kapalıyken de). Yalnızca düğme sırası
///   seçiliyken düğmeler arasında gezinir.
/// - Aşağı: "Sırada" panelini açar.
/// - Yukarı: panel açıksa kapatır; değilse düğme sırasına geçer.
/// - Geri: panel/kontroller açıksa onları kapatır, kapalıysa ekrandan çıkar.
class TvPlayer extends StatefulWidget {
  const TvPlayer({
    super.key,
    required this.details,
    required this.playback,
    required this.coordinator,
  });

  /// Hazırlık sürerken null olabilir. Ekran o durumda da AYNI ağaçla çizilir
  /// (bkz. [build]).
  final VideoDetails? details;
  final PlaybackClient playback;
  final PlaybackCoordinator coordinator;

  @override
  State<TvPlayer> createState() => _TvPlayerState();
}

/// Kontroller açıkken seçimin hangi sırada olduğu.
enum _Row { play, buttons }

class _TvPlayerState extends State<TvPlayer> {
  /// Kumandada tuşlar arasında telefondakinden uzun aralıklar oluyor; 3 saniye
  /// kullanıcı daha düğmeye bakarken kontrolleri kapatıyordu.
  static const _autoHide = Duration(seconds: 5);
  static const _seekStep = Duration(seconds: 10);

  final _focus = FocusNode(debugLabel: 'tvPlayer');

  bool _controlsVisible = false;
  bool _panelOpen = false;
  bool _qualityOpen = false;
  _Row _row = _Row.play;

  /// Düğme sırasındaki seçim: 0 önceki, 1 kalite, 2 sonraki.
  int _buttonIndex = 1;
  int _panelIndex = 0;
  int _qualityIndex = 0;

  Timer? _hideTimer;

  String? _seekHint;
  Timer? _hintTimer;

  /// Peş peşe basılan sarma tuşlarının BİRİKMESİ için hedef konum.
  ///
  /// Yalnızca [PlaybackState.position]'a bakılsaydı, ikinci basış native'ten
  /// güncel konum daha gelmeden yapıldığı için aynı yere sarardı: kullanıcı üç
  /// kez bassa da video 10 saniye ilerlerdi.
  Duration? _seekTarget;
  Timer? _seekSettle;

  PlaybackState _state = const PlaybackState();

  @override
  void initState() {
    super.initState();
    // Üstteki oynatma ekranı da `autofocus` istiyor; odağı ondan geri almak
    // için ilk kareden sonra açıkça talep ediliyor. Odak orada kalırsa tuşlar
    // buraya hiç ulaşmaz.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    _seekSettle?.cancel();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- görünürlük

  void _touch() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHide, () {
      if (!mounted) return;
      setState(() {
        _controlsVisible = false;
        _panelOpen = false;
        _qualityOpen = false;
        _row = _Row.play;
      });
    });
  }

  void _showControls() {
    setState(() {
      _controlsVisible = true;
      _row = _Row.play;
    });
    _touch();
  }

  bool _hideEverything() {
    if (!_controlsVisible && !_panelOpen && !_qualityOpen) return false;
    _hideTimer?.cancel();
    setState(() {
      _controlsVisible = false;
      _panelOpen = false;
      _qualityOpen = false;
      _row = _Row.play;
    });
    return true;
  }

  // -------------------------------------------------------------------- eylem

  Future<void> _togglePlay() async {
    if (_state.playWhenReady) {
      await widget.playback.pause();
    } else {
      await widget.playback.resume();
    }
  }

  void _seekBy(Duration offset) {
    // Canlı yayında sarma yok: konum çubuğu da yok, hedef anlamsız.
    if (_state.isLive) return;

    final base = _seekTarget ?? _state.position;
    var target = base + offset;
    if (target < Duration.zero) target = Duration.zero;
    final duration = _state.duration;
    if (duration != null && target > duration) target = duration;

    widget.playback.seekTo(target);

    _seekSettle?.cancel();
    _seekSettle = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _seekTarget = null);
    });

    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _seekHint = null);
    });

    setState(() {
      _seekTarget = target;
      _seekHint = offset.isNegative
          ? '${offset.inSeconds.abs()} sn geri'
          : '${offset.inSeconds} sn ileri';
      // Sarınca konum çubuğu görünsün: kullanıcı nereye gittiğini görmeli.
      _controlsVisible = true;
    });
    _touch();
  }

  void _openPanel() {
    final queue = widget.coordinator.queue;
    if (queue.isEmpty) return;
    setState(() {
      _panelOpen = true;
      _controlsVisible = true;
      // Seçim "sırada olan"dan başlasın; çalan videoya basmak anlamsız.
      final next = widget.coordinator.queueIndex + 1;
      _panelIndex = next >= 0 && next < queue.length ? next : 0;
    });
    _touch();
  }

  void _openQuality() {
    setState(() {
      _qualityOpen = true;
      _qualityIndex = 0;
    });
    _touch();
  }

  void _activateButton() {
    switch (_buttonIndex) {
      case 0:
        widget.coordinator.playPrevious();
      case 1:
        _openQuality();
      case 2:
        widget.coordinator.playNext();
    }
    _touch();
  }

  // --------------------------------------------------------------------- tuş

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Tuşu basılı tutmak sarmayı sürdürsün diye tekrar olayları da işleniyor.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    const okKeys = {
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.gameButtonA,
    };

    // Medya tuşları her durumda aynı işi yapar.
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      _touch();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(_seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-_seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      widget.coordinator.playNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      widget.coordinator.playPrevious();
      return KeyEventResult.handled;
    }
    // Kumandanın "geri" tuşu bazı televizyonlarda gezinme olayı yerine ham
    // tuş olarak geliyor; ikisi de aynı yere bağlanıyor.
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      return _handleBack() ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    if (_qualityOpen) return _qualityKey(key, okKeys);
    if (_panelOpen) return _panelKey(key, okKeys);

    if (!_controlsVisible) {
      if (key == LogicalKeyboardKey.arrowRight) {
        _seekBy(_seekStep);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _seekBy(-_seekStep);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _openPanel();
        return KeyEventResult.handled;
      }
      // Yukarı ve OK dahil kalan her tuş kontrolleri geri getirir: kontroller
      // gizliyken kullanıcının elinde başka yol yok.
      _showControls();
      return KeyEventResult.handled;
    }

    if (okKeys.contains(key)) {
      if (_row == _Row.play) {
        _togglePlay();
        _touch();
      } else {
        _activateButton();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (_row == _Row.buttons) {
        setState(() => _buttonIndex = (_buttonIndex + 1) % 3);
        _touch();
      } else {
        _seekBy(_seekStep);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_row == _Row.buttons) {
        setState(() => _buttonIndex = (_buttonIndex + 2) % 3);
        _touch();
      } else {
        _seekBy(-_seekStep);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_row == _Row.buttons) {
        setState(() => _row = _Row.play);
        _touch();
      } else {
        _openPanel();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _row = _Row.buttons);
      _touch();
      return KeyEventResult.handled;
    }

    _touch();
    return KeyEventResult.ignored;
  }

  KeyEventResult _panelKey(LogicalKeyboardKey key, Set<LogicalKeyboardKey> ok) {
    final queue = widget.coordinator.queue;
    if (key == LogicalKeyboardKey.arrowRight) {
      setState(() => _panelIndex = (_panelIndex + 1).clamp(0, queue.length - 1));
      _touch();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      setState(() => _panelIndex = (_panelIndex - 1).clamp(0, queue.length - 1));
      _touch();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _panelOpen = false);
      _touch();
      return KeyEventResult.handled;
    }
    if (ok.contains(key)) {
      if (_panelIndex >= 0 && _panelIndex < queue.length) {
        widget.coordinator.playQueueIndex(_panelIndex);
      }
      setState(() {
        _panelOpen = false;
        _controlsVisible = false;
      });
      _hideTimer?.cancel();
      return KeyEventResult.handled;
    }
    _touch();
    return KeyEventResult.handled;
  }

  KeyEventResult _qualityKey(
    LogicalKeyboardKey key,
    Set<LogicalKeyboardKey> ok,
  ) {
    // 0 = "En yüksek", sonrası gerçek çözünürlükler.
    final count = widget.coordinator.availableQualities.length + 1;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _qualityIndex = (_qualityIndex + 1) % count);
      _touch();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _qualityIndex = (_qualityIndex - 1 + count) % count);
      _touch();
      return KeyEventResult.handled;
    }
    if (ok.contains(key)) {
      final options = widget.coordinator.availableQualities;
      if (options.isNotEmpty) {
        widget.coordinator.setQuality(
          _qualityIndex == 0 ? null : options[_qualityIndex - 1],
        );
      }
      setState(() => _qualityOpen = false);
      _touch();
      return KeyEventResult.handled;
    }
    _touch();
    return KeyEventResult.handled;
  }

  /// Geri tuşu ekrandan çıkmadan önce açık katmanları kapatır.
  /// Kapatacak bir şey yoksa false döner ve çıkışa izin verilir.
  bool _handleBack() {
    if (_qualityOpen) {
      setState(() => _qualityOpen = false);
      _touch();
      return true;
    }
    if (_panelOpen) {
      setState(() => _panelOpen = false);
      _touch();
      return true;
    }
    return _hideEverything();
  }

  // ------------------------------------------------------------------- çizim

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_handleBack()) return;
        Navigator.of(context).pop();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: StreamBuilder<PlaybackState>(
            stream: widget.playback.stateStream,
            builder: (context, snapshot) {
              _state = snapshot.data ?? _state;
              return _buildStack(context, _state);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStack(BuildContext context, PlaybackState state) {
    final details = widget.details;
    final overlay = _controlsVisible || _panelOpen || _qualityOpen;

    // Katman sırası hiç değişmiyor ve video HER ZAMAN 0. sırada duruyor.
    // Daha önce hazırlık sürerken bambaşka bir ağaç döndürülüyordu; Flutter
    // yüzeyi yok edip yeniden kuruyor, native doku kopuyor ve ekran siyah
    // kalıyordu.
    return Stack(
      fit: StackFit.expand,
      children: [
        _TvVideoLayer(state: state, posterUrl: details?.thumbnailUrl),

        // Kontroller açıkken görüntü hafifçe karartılır: beyaz yazılar açık
        // sahnelerde okunmuyordu.
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: overlay ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent, Colors.black87],
                  stops: [0, 0.45, 1],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _seekHint == null ? 0 : 1,
              duration: const Duration(milliseconds: 120),
              child: Center(
                child: _SeekBadge(text: _seekHint ?? ''),
              ),
            ),
          ),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: _buildControls(context, state, details),
            ),
          ),
        ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _panelOpen
              ? _UpNextPanel(
                  queue: widget.coordinator.queue,
                  playingIndex: widget.coordinator.queueIndex,
                  selected: _panelIndex,
                )
              : const SizedBox.shrink(),
        ),

        Positioned(
          right: 48,
          top: 0,
          bottom: 0,
          child: _qualityOpen
              ? _QualityOverlay(
                  options: widget.coordinator.availableQualities,
                  selected: _qualityIndex,
                  current: widget.coordinator.qualityLabel,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildControls(
    BuildContext context,
    PlaybackState state,
    VideoDetails? details,
  ) {
    final playing = state.playWhenReady;

    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 32, 48, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            details?.title ?? widget.coordinator.pending?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              ?details?.uploaderName,
              ?widget.coordinator.qualityLabel,
            ].join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),

          const Spacer(),

          // Ortadaki büyük oynat/duraklat. Kontroller açılınca seçim burada
          // olur: kullanıcının ilk isteyeceği şey bu.
          Center(
            child: _TvButton(
              icon: playing ? Icons.pause : Icons.play_arrow,
              selected: _row == _Row.play,
              size: 64,
            ),
          ),

          const Spacer(),

          _ProgressRow(state: state, seekTarget: _seekTarget),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TvButton(
                icon: Icons.skip_previous,
                selected: _row == _Row.buttons && _buttonIndex == 0,
                enabled: state.hasPrevious,
                label: 'Önceki',
              ),
              const SizedBox(width: 24),
              _TvButton(
                icon: Icons.high_quality_outlined,
                selected: _row == _Row.buttons && _buttonIndex == 1,
                label: 'Kalite',
              ),
              const SizedBox(width: 24),
              _TvButton(
                icon: Icons.skip_next,
                selected: _row == _Row.buttons && _buttonIndex == 2,
                enabled: state.hasNext,
                label: 'Sonraki',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Sırada olanlar için AŞAĞI • sarmak için SOL/SAĞ',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Video yüzeyi katmanı.
///
/// Yapısı HİÇ değişmez: yalnızca `SizedBox`'ın ölçüleri en-boy oranıyla
/// güncellenir. Sarmalayıcıyı koşullu hale getirmek (yükleniyorken başka bir
/// ağaç) native yüzeyi kopardığı için görüntü siyah kalıyordu.
class _TvVideoLayer extends StatelessWidget {
  const _TvVideoLayer({required this.state, required this.posterUrl});

  final PlaybackState state;
  final String? posterUrl;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: state.aspectRatio * 1000,
              height: 1000,
              child: const VideoSurface(),
            ),
          ),
        ),

        // İlk kare gelene kadar yüzeyde ÖNCEKİ videonun karesi durur; onun
        // yerine yeni videonun kapağı gösterilir.
        if (!state.hasVideoFrame) ...[
          if (posterUrl != null) Image.network(posterUrl!, fit: BoxFit.cover),
          Container(color: Colors.black.withValues(alpha: 0.55)),
        ],

        if (!state.hasVideoFrame || state.isBuffering)
          const Center(
            child: SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Geçen süre, ilerleme çubuğu, kalan süre.
class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.state, required this.seekTarget});

  final PlaybackState state;

  /// Sarma isteği native'e ulaşmadan çubuk yerinden oynasın; yoksa tuşa
  /// basınca ekranda bir şey olmuyormuş gibi duruyordu.
  final Duration? seekTarget;

  @override
  Widget build(BuildContext context) {
    if (state.isLive) {
      return const Row(
        children: [
          Icon(Icons.circle, color: Colors.red, size: 12),
          SizedBox(width: 8),
          Text('CANLI', style: TextStyle(color: Colors.white, fontSize: 16)),
        ],
      );
    }

    final duration = state.duration ?? Duration.zero;
    final position = seekTarget ?? state.position;
    final total = duration.inMilliseconds;
    final ratio = total == 0
        ? 0.0
        : (position.inMilliseconds / total).clamp(0.0, 1.0);
    final buffered = total == 0
        ? 0.0
        : (state.bufferedPosition.inMilliseconds / total).clamp(0.0, 1.0);

    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            _fmt(position),
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 6,
            child: Stack(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const SizedBox.expand(),
                ),
                FractionallySizedBox(
                  widthFactor: buffered,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white38,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: ratio,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: 76,
          child: Text(
            // Kalan süre, toplam süreden daha çok işe yarıyor: "ne kadar var".
            '-${_fmt(duration - position)}',
            textAlign: TextAlign.right,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      ],
    );
  }
}

/// Kumandayla seçilen düğme. Gerçek bir [IconButton] DEĞİL: odaklanabilir bir
/// düğüm olsaydı ok tuşları Flutter'ın dolaşımına kaçar, tuş haritası
/// bozulurdu. Seçim çerçevesi elle çiziliyor.
class _TvButton extends StatelessWidget {
  const _TvButton({
    required this.icon,
    required this.selected,
    this.size = 34,
    this.enabled = true,
    this.label,
  });

  final IconData icon;
  final bool selected;
  final double size;
  final bool enabled;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Colors.white : Colors.white30;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.all(size * 0.32),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? Colors.white : Colors.black45,
            border: Border.all(
              color: selected ? Colors.white : Colors.white24,
              width: 2,
            ),
          ),
          child: Icon(
            icon,
            size: size,
            color: selected ? Colors.black : color,
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(
            label!,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white54,
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}

/// "10 sn ileri" balonu.
class _SeekBadge extends StatelessWidget {
  const _SeekBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Aşağı ok ile açılan "Sırada" paneli.
class _UpNextPanel extends StatelessWidget {
  const _UpNextPanel({
    required this.queue,
    required this.playingIndex,
    required this.selected,
  });

  final List<VideoSummary> queue;
  final int playingIndex;
  final int selected;

  static const _itemWidth = 240.0;
  static const _gap = 16.0;

  @override
  Widget build(BuildContext context) {
    // Seçili öğe ekrandan taşmasın: liste kaydırma yerine kaydırılmış bir
    // konumla çiziliyor — kumandayla gezerken kaydırma denetleyicisinin
    // animasyonu tuş tekrarında geride kalıyordu.
    final width = MediaQuery.sizeOf(context).width;
    final visible = ((width - 96) / (_itemWidth + _gap)).floor().clamp(1, 12);
    final first = (selected - visible ~/ 2).clamp(
      0,
      (queue.length - visible).clamp(0, queue.length),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(48, 20, 48, 32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Sırada',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: Row(
              children: [
                for (var i = first; i < queue.length && i < first + visible; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: _gap),
                    child: _QueueCard(
                      video: queue[i],
                      selected: i == selected,
                      playing: i == playingIndex,
                      width: _itemWidth,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({
    required this.video,
    required this.selected,
    required this.playing,
    required this.width,
  });

  final VideoSummary video;
  final bool selected;
  final bool playing;
  final double width;

  @override
  Widget build(BuildContext context) {
    final thumb = video.thumbnailUrl;

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? Colors.white : Colors.transparent,
                width: 3,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: Colors.white10),
                    if (thumb != null) Image.network(thumb, fit: BoxFit.cover),
                    if (playing)
                      const ColoredBox(
                        color: Colors.black54,
                        child: Center(
                          child: Icon(
                            Icons.equalizer,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// Kalite listesi.
///
/// Telefondaki `showQualityMenu` bir alt sayfa açıyor; televizyonda o sayfa
/// kendi odak alanını kurup tuş haritasını devralıyordu. Burada seçim yine
/// [TvPlayer] tarafından yönetiliyor.
class _QualityOverlay extends StatelessWidget {
  const _QualityOverlay({
    required this.options,
    required this.selected,
    required this.current,
  });

  final List<int> options;
  final int selected;
  final String? current;

  @override
  Widget build(BuildContext context) {
    // Seçenek yoksa liste de boş kalmalı: "En yüksek" tek başına seçilebilir
    // görünüp hiçbir şey yapmıyordu.
    final labels = options.isEmpty
        ? const <String>[]
        : ['En yüksek', for (final h in options) '${h}p'];

    return Center(
      child: Container(
        width: 260,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                current == null ? 'Kalite' : 'Kalite • $current',
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Text(
                  'Bu video için seçenek yok.',
                  style: TextStyle(color: Colors.white54, fontSize: 15),
                ),
              ),
            for (var i = 0; i < labels.length; i++)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                color: i == selected ? Colors.white : Colors.transparent,
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: i == selected ? Colors.black : Colors.white,
                    fontSize: 17,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
