import 'package:flutter/material.dart';
import 'package:olustiff/core/ui/thumb_image.dart';

import '../../core/cast/youtube_cast_controller.dart';
import '../../core/i18n/lang.dart';

/// Televizyonun kendi YouTube'una gönderilirken oynatma ekranının yerini alan
/// kumanda.
///
/// [CastPanel]'den AYRI, çünkü arkalarındaki protokoller farklı ve hata
/// hâlleri farklı görünüyor. İki ekranı tek koda sığdırmak, hangi yolun
/// hangi kontrolü desteklediğini dallandıran bir yapı doğururdu.
///
/// Panel İKİ hâlde çalışıyor:
/// - Televizyon durumunu bildiriyorsa ([YouTubeCastController.hasLiveStatus])
///   konum çubuğu ve TEK bir oynat/duraklat düğmesi var; gösterilen her şey
///   televizyonun kendi bildirdiği değer.
/// - Bildirmiyorsa iki ayrı düğmeye ve çubuksuz görünüme düşülüyor —
///   okunamayan bir durumu tahmin ederek çizmek, çubuğu hiç göstermemekten
///   kötü.
class YouTubeCastPanel extends StatelessWidget {
  const YouTubeCastPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final cast = YouTubeCastController.instance;
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: cast,
      builder: (context, _) {
        final device = cast.device;
        // Bağlantı bu arada kesildiyse ekran kendiliğinden oynatıcıya dönsün.
        if (device == null) return const SizedBox.shrink();

        final thumbnailUrl = cast.thumbnailUrl;

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (thumbnailUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ThumbImage(
                      thumbnailUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Colors.black26,
                        child: Center(child: Icon(Icons.tv, size: 48)),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.smart_display_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tr("${device.name} · YouTube'da oynatılıyor", '${device.name} · Playing in YouTube'),
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                cast.title ?? '',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              // Çubuk yalnızca televizyon konumunu bildiriyorken çiziliyor.
              if (cast.hasLiveStatus)
                _CastProgress(
                  position: cast.position ?? Duration.zero,
                  duration: cast.duration,
                  onSeek: cast.seekTo,
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: tr('Önceki', 'Previous'),
                    icon: const Icon(Icons.skip_previous),
                    onPressed: cast.isBusy ? null : cast.previous,
                  ),
                  const SizedBox(width: 8),
                  if (cast.hasLiveStatus)
                    // Tek düğme: televizyonun bildirdiği duruma göre biçim
                    // değiştiriyor. Komut yerel ağdan gidiyor (~1 ms), bu
                    // yüzden `isBusy` ile kilitlenmiyor — kilitlemek düğmeyi
                    // sebepsiz donuk gösterirdi.
                    FilledButton.tonalIcon(
                      icon: Icon(
                        cast.isPlaying == true ? Icons.pause : Icons.play_arrow,
                      ),
                      label: Text(
                        cast.isPlaying == true ? tr('Duraklat', 'Pause') : tr('Oynat', 'Play'),
                      ),
                      onPressed:
                          cast.isPlaying == true ? cast.pause : cast.play,
                    )
                  else ...[
                    // Durum okunamıyor: hangi hâlde olduğumuzu iddia etmeden
                    // iki düğme de her zaman ne yazdığını yapıyor.
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.play_arrow),
                      label: Text(tr('Oynat', 'Play')),
                      onPressed: cast.isBusy ? null : cast.play,
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.pause),
                      label: Text(tr('Duraklat', 'Pause')),
                      onPressed: cast.isBusy ? null : cast.pause,
                    ),
                  ],
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: tr('Sonraki', 'Next'),
                    icon: const Icon(Icons.skip_next),
                    onPressed: cast.isBusy ? null : cast.next,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Ses televizyondan OKUNABİLDİĞİ için gösteriliyor; okunamazsa
              // (eski cihaz, cevapsız kanal) hiç gösterilmiyor.
              if (cast.volume != null)
                _TvVolume(
                  volume: cast.volume!,
                  isMuted: cast.isMuted,
                  onChanged: cast.setVolume,
                  onToggleMute: cast.toggleMute,
                ),
              const SizedBox(height: 8),
              if (!cast.hasLiveStatus) const _RemoteLimitsNote(),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(tr('Televizyonda durdur', 'Stop on TV')),
                    onPressed: cast.isBusy ? null : cast.stopRemote,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: Text(tr('Bağlantıyı kes', 'Disconnect')),
                    onPressed: cast.isBusy ? null : cast.disconnect,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Kumandanın neyi yapamadığını açıkça söyleyen not.
///
/// Sessizce eksik bırakmak "uygulama bozuk" izlenimi veriyordu: kullanıcı
/// konum çubuğunu arıyor, bulamayınca hata sanıyor. Sebebini bir cümleyle
/// söylemek, eksikliği anlaşılır bir sınıra çeviriyor.
class _RemoteLimitsNote extends StatelessWidget {
  const _RemoteLimitsNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: theme.textTheme.bodySmall?.color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            tr(
              "Televizyonun kendi YouTube'u çalıyor; kaldığı yeri telefona "
              'bildirmiyor. Sarma işlemini televizyonun kumandasından '
              'yapabilirsiniz.',
              "The TV's own YouTube app is playing and doesn't report its "
              "position to the phone. Use the TV's remote to seek.",
            ),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Televizyondaki videonun konum çubuğu.
///
/// Gösterdiği değer televizyonun kendi bildirdiği konum; iki bildirim arası
/// saatle ilerletiliyor (bkz. [YouTubeCastController.position]).
class _CastProgress extends StatefulWidget {
  const _CastProgress({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;

  /// Alıcı süreyi bildirmediyse null — o hâlde çubuk yerine yalnızca geçen
  /// süre yazılıyor, çünkü sonu bilinmeyen bir çubuk yanlış bilgi verir.
  final Duration? duration;

  final ValueChanged<Duration> onSeek;

  @override
  State<_CastProgress> createState() => _CastProgressState();
}

class _CastProgressState extends State<_CastProgress> {
  /// Sürükleme sürerken parmağın takip ettiği saniye.
  ///
  /// Televizyondan gelen konum sürükleme sırasında dinlenmiyor: her saniye
  /// gelen gerçek değer, parmağın altındaki noktayı geri sıçratırdı.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.duration;

    if (total == null || total.inMilliseconds <= 0) {
      return Text(
        _format(widget.position),
        style: theme.textTheme.bodySmall,
      );
    }

    final maxSeconds = total.inMilliseconds / 1000;
    final current =
        _dragging ?? (widget.position.inMilliseconds / 1000).clamp(0.0, maxSeconds);

    return Column(
      children: [
        Slider(
          value: current.clamp(0.0, maxSeconds),
          max: maxSeconds,
          onChanged: (v) => setState(() => _dragging = v),
          onChangeEnd: (v) {
            setState(() => _dragging = null);
            widget.onSeek(Duration(milliseconds: (v * 1000).round()));
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _format(Duration(milliseconds: (current * 1000).round())),
                style: theme.textTheme.bodySmall,
              ),
              Text(_format(total), style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  /// Süreyi "d:ss" ya da bir saati aşıyorsa "s:dd:ss" olarak yazar.
  static String _format(Duration value) {
    final seconds = value.inSeconds;
    final s = (seconds % 60).toString().padLeft(2, '0');
    final m = (seconds ~/ 60) % 60;
    final h = seconds ~/ 3600;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
    return '$m:$s';
  }
}

/// Televizyonun ana sesini yöneten satır.
class _TvVolume extends StatefulWidget {
  const _TvVolume({
    required this.volume,
    required this.isMuted,
    required this.onChanged,
    required this.onToggleMute,
  });

  final double volume;
  final bool isMuted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

  @override
  State<_TvVolume> createState() => _TvVolumeState();
}

class _TvVolumeState extends State<_TvVolume> {
  /// Sürükleme sürerken kaydırıcının takip ettiği değer.
  ///
  /// Televizyondan gelen seviye komuttan sonra yeniden okunuyor; sürükleme
  /// sırasında onu dinlemek parmağın altındaki noktayı geri sıçratırdı.
  double? _dragging;

  IconData get _icon {
    if (widget.isMuted || widget.volume <= 0) return Icons.volume_off;
    return widget.volume < 0.5 ? Icons.volume_down : Icons.volume_up;
  }

  @override
  Widget build(BuildContext context) {
    final value = _dragging ?? widget.volume.clamp(0.0, 1.0);
    return Row(
      children: [
        IconButton(
          tooltip: widget.isMuted ? tr('Sesi aç', 'Unmute') : tr('Sesi kapat', 'Mute'),
          icon: Icon(_icon),
          onPressed: widget.onToggleMute,
        ),
        Expanded(
          child: Slider(
            value: value,
            onChanged: (v) => setState(() => _dragging = v),
            onChangeEnd: (v) {
              setState(() => _dragging = null);
              widget.onChanged(v);
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            tr('%${(value * 100).round()}', '${(value * 100).round()}%'),
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
