import 'package:flutter/material.dart';
import 'package:olustiff/core/ui/thumb_image.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import 'cast_disconnect.dart';
import '../../core/i18n/lang.dart';

/// Yayın açıkken oynatma ekranının yerini alan kumanda.
///
/// Telefonda görüntü YOK: video televizyonda. Ekranın burada oynatıcı gibi
/// davranmaya çalışması (kararmış bir video yüzeyi göstermesi) "bozuldu"
/// hissi veriyordu; bunun yerine ekran açıkça bir kumandaya dönüşüyor.
class CastPanel extends StatelessWidget {
  const CastPanel({
    super.key,
    required this.title,
    this.thumbnailUrl,
    this.videoId,
  });

  final String title;
  final String? thumbnailUrl;

  /// Televizyonda çalan video. "Telefonda devam et" bunu telefonda açıyor.
  final String? videoId;

  @override
  Widget build(BuildContext context) {
    final cast = CastController.instance;
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: cast,
      builder: (context, _) {
        final device = cast.device;
        // Bağlantı bu arada kesildiyse (kullanıcı listeden kesti) ekran
        // kendiliğinden normal oynatıcıya dönsün.
        if (device == null) return const SizedBox.shrink();

        final state = cast.remoteState;
        final position = state?.position ?? Duration.zero;
        final duration = state?.duration;
        final playing = state?.isPlaying ?? false;

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
                      thumbnailUrl!,
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
                  Icon(Icons.cast_connected, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tr('${device.name} cihazında oynatılıyor', 'Playing on ${device.name}'),
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              _RemoteProgress(
                position: position,
                duration: duration,
                onSeek: cast.seekTo,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: tr('Önceki', 'Previous'),
                    icon: const Icon(Icons.skip_previous),
                    onPressed: cast.previous,
                  ),
                  IconButton(
                    tooltip: tr('10 saniye geri', 'Back 10 seconds'),
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => cast.seekTo(
                      _clamp(position - const Duration(seconds: 10)),
                    ),
                  ),
                  IconButton.filled(
                    iconSize: 36,
                    tooltip: playing ? tr('Duraklat', 'Pause') : tr('Oynat', 'Play'),
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: playing ? cast.pause : cast.resume,
                  ),
                  IconButton(
                    tooltip: tr('10 saniye ileri', 'Forward 10 seconds'),
                    icon: const Icon(Icons.forward_10),
                    onPressed: () =>
                        cast.seekTo(position + const Duration(seconds: 10)),
                  ),
                  IconButton(
                    tooltip: tr('Sonraki', 'Next'),
                    icon: const Icon(Icons.skip_next),
                    onPressed: cast.next,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Ses seviyesi televizyon bildirmediyse (okunamıyorsa) hiç
              // gösterilmiyor: çalışmayan bir kaydırıcı, olmayandan kötü.
              if (cast.volume != null)
                _RemoteVolume(
                  volume: cast.volume!,
                  isMuted: cast.isMuted,
                  onChanged: cast.setVolume,
                  onToggleMute: cast.toggleMute,
                ),
              const SizedBox(height: 8),
              // Tek düğme: "bitir" dendiğinde ne olacağını kullanıcı seçiyor
              // (televizyonda dursun mu, telefonda devam mı, ikisi de sussun
              // mu). Üç düğmeyi yan yana koymak bu küçük ekranda hem
              // sığmıyor hem de hangisinin ne yaptığı okunmuyordu.
              FilledButton.tonalIcon(
                icon: const Icon(Icons.cast_connected),
                label: Text(tr('Bağlantıyı kes', 'Disconnect')),
                onPressed: () => showCastDisconnectOptions(context),
              ),
              const SizedBox(height: 16),
              // Kumandanın altında "sırada ne var": kullanıcı televizyonun
              // karşısına gitmeden hem görebilsin hem de atlayabilsin.
              const _CastQueue(),
            ],
          ),
        );
      },
    );
  }

  static Duration _clamp(Duration value) =>
      value < Duration.zero ? Duration.zero : value;
}

/// Televizyondaki konumu gösteren ve sarma yapan çubuk.
class _RemoteProgress extends StatefulWidget {
  const _RemoteProgress({
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration? duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<_RemoteProgress> createState() => _RemoteProgressState();
}

class _RemoteProgressState extends State<_RemoteProgress> {
  /// Sürükleme sürerken çubuğun takip ettiği değer.
  ///
  /// Televizyondan gelen konum saniyede bir güncelleniyor; sürükleme
  /// sırasında onu dinlemek parmağın altındaki noktayı geri sıçratırdı.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration?.inMilliseconds.toDouble() ?? 0;
    // Süre henüz bilinmiyor (ya da canlı yayın): sarma yapılamaz.
    if (total <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(_format(widget.position)),
      );
    }

    final value =
        _dragging ?? widget.position.inMilliseconds.toDouble().clamp(0, total);

    return Column(
      children: [
        Slider(
          value: value.toDouble(),
          max: total,
          onChanged: (v) => setState(() => _dragging = v),
          onChangeEnd: (v) {
            setState(() => _dragging = null);
            widget.onSeek(Duration(milliseconds: v.round()));
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(Duration(milliseconds: value.round()))),
              Text(_format(widget.duration!)),
            ],
          ),
        ),
      ],
    );
  }

  static String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
  }
}


/// Televizyonun sesini yöneten satır.
class _RemoteVolume extends StatefulWidget {
  const _RemoteVolume({
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
  State<_RemoteVolume> createState() => _RemoteVolumeState();
}

class _RemoteVolumeState extends State<_RemoteVolume> {
  /// Sürükleme sürerken kaydırıcının takip ettiği değer.
  ///
  /// Televizyondan gelen seviye saniyede bir güncelleniyor; sürükleme
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
            // Sessizdeyken kaydırıcı sıfırda değil, kısılmış SEVİYEDE
            // duruyor; sessizlik ayrı bir durum ve simgeden okunuyor.
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


/// Yayın açıkken "Sırada" listesi.
///
/// Dokunulan video televizyonda açılıyor: [PlaybackCoordinator.playQueueIndex]
/// yayın açıkken komutu televizyona yönlendiriyor, telefonda ses açılmıyor.
class _CastQueue extends StatelessWidget {
  const _CastQueue();

  @override
  Widget build(BuildContext context) {
    final coordinator = PlaybackCoordinator.instance;
    return AnimatedBuilder(
      animation: coordinator,
      builder: (context, _) {
        final queue = coordinator.queue;
        // Çalan videodan sonrası. Kuyruk tek parçadan ibaretse gösterecek bir
        // şey yok; boş bir başlık bırakmıyoruz.
        final start = coordinator.queueIndex + 1;
        if (start < 1 || start >= queue.length) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Sırada', 'Up next'), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (var i = start; i < queue.length; i++)
              _CastQueueTile(
                summary: queue[i],
                onTap: () => coordinator.playQueueIndex(i),
              ),
          ],
        );
      },
    );
  }
}

class _CastQueueTile extends StatelessWidget {
  const _CastQueueTile({required this.summary, required this.onTap});

  final VideoSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnail = summary.thumbnailUrl;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 84,
        height: 48,
        child: thumbnail == null
            ? const ColoredBox(
                color: Colors.black26,
                child: Icon(Icons.music_note),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: ThumbImage(
                  thumbnail,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.music_note),
                  ),
                ),
              ),
      ),
      title: Text(
        summary.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      subtitle: summary.uploaderName == null
          ? null
          : Text(
              summary.uploaderName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      // Yayın açıkken televizyonda açılır; telefonda ses çıkmaz.
      trailing: const Icon(Icons.cast, size: 18),
      onTap: onTap,
    );
  }
}
