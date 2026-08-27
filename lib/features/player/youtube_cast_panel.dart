import 'package:flutter/material.dart';

import '../../core/cast/youtube_cast_controller.dart';

/// Televizyonun kendi YouTube'una gönderilirken oynatma ekranının yerini alan
/// kumanda.
///
/// [CastPanel]'den AYRI, çünkü sunabildikleri farklı. Orada televizyondaki
/// uygulama bize durumunu bildiriyor (konum, süre, çalıyor mu); burada
/// bildirmiyor. İki ekranı tek koda sığdırmak, olmayan veriyi varmış gibi
/// gösteren dallanmalar doğururdu.
///
/// Bu yüzden burada konum çubuğu YOK ve oynat/duraklat tek bir düğme değil.
/// Gerekçesi [YouTubeCastController] belgesinde.
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
                    child: Image.network(
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
                      "${device.name} · YouTube'da oynatılıyor",
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
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Önceki',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: cast.isBusy ? null : cast.previous,
                  ),
                  const SizedBox(width: 8),
                  // Oynat ve Duraklat AYRI düğmeler: televizyonun o an çalıp
                  // çalmadığını okuyamıyoruz, dolayısıyla tek bir düğmenin
                  // göstereceği durum tahmin olurdu.
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Oynat'),
                    onPressed: cast.isBusy ? null : cast.play,
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.pause),
                    label: const Text('Duraklat'),
                    onPressed: cast.isBusy ? null : cast.pause,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Sonraki',
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
              const _RemoteLimitsNote(),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Televizyonda durdur'),
                    onPressed: cast.isBusy ? null : cast.stopRemote,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: const Text('Bağlantıyı kes'),
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
            "Televizyonun kendi YouTube'u çalıyor; kaldığı yeri telefona "
            'bildirmiyor. Sarma işlemini televizyonun kumandasından '
            'yapabilirsiniz.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
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
          tooltip: widget.isMuted ? 'Sesi aç' : 'Sesi kapat',
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
            '%${(value * 100).round()}',
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
