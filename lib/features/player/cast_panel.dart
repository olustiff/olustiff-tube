import 'package:flutter/material.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/playback/playback_client.dart';

/// Yayın açıkken oynatma ekranının yerini alan kumanda.
///
/// Telefonda görüntü YOK: video televizyonda. Ekranın burada oynatıcı gibi
/// davranmaya çalışması (kararmış bir video yüzeyi göstermesi) "bozuldu"
/// hissi veriyordu; bunun yerine ekran açıkça bir kumandaya dönüşüyor.
class CastPanel extends StatelessWidget {
  const CastPanel({super.key, required this.title, this.thumbnailUrl});

  final String title;
  final String? thumbnailUrl;

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
                    child: Image.network(
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
                      '${device.name} cihazında oynatılıyor',
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
                    tooltip: 'Önceki',
                    icon: const Icon(Icons.skip_previous),
                    onPressed: cast.previous,
                  ),
                  IconButton(
                    tooltip: '10 saniye geri',
                    icon: const Icon(Icons.replay_10),
                    onPressed: () => cast.seekTo(
                      _clamp(position - const Duration(seconds: 10)),
                    ),
                  ),
                  IconButton.filled(
                    iconSize: 36,
                    tooltip: playing ? 'Duraklat' : 'Oynat',
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                    onPressed: playing ? cast.pause : cast.resume,
                  ),
                  IconButton(
                    tooltip: '10 saniye ileri',
                    icon: const Icon(Icons.forward_10),
                    onPressed: () =>
                        cast.seekTo(position + const Duration(seconds: 10)),
                  ),
                  IconButton(
                    tooltip: 'Sonraki',
                    icon: const Icon(Icons.skip_next),
                    onPressed: cast.next,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Telefonda devam et'),
                    onPressed: () => _continueOnPhone(position),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text("TV'de durdur"),
                    onPressed: cast.stopRemote,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Yayını kapatıp telefonu televizyonun kaldığı yerden sürdürür.
  /// Televizyondaki oynatma durdurulur — yoksa aynı ses iki yerden gelirdi.
  Future<void> _continueOnPhone(Duration position) async {
    await CastController.instance.stopRemote();
    await PlaybackClient.shared.seekTo(position);
    await PlaybackClient.shared.resume();
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
