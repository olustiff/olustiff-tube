import 'package:flutter/material.dart';

import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/content_kind.dart';
import '../../core/playback/now_playing.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/stream_selection.dart';
import 'video_surface.dart';

/// Oynatma ekranı.
///
/// Davranış sözleşmesi:
/// - Müzik içeriği varsayılan olarak SESLİ modda açılır, video içeriği video
///   modunda. Bu tespit yalnızca açılışta yapılır.
/// - Kullanıcı modu elle değiştirebilir; seçtiği mod kendiliğinden geri
///   dönmez.
/// - Sesli moddayken video yüzeyi hiç oluşturulmaz ve video parçası hiç
///   indirilmez; ekrandan çıkıldığında oynatma arka planda sürer.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.videoId});

  final String videoId;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _extraction = ExtractionClient();
  final _playback = PlaybackClient.shared;

  VideoDetails? _details;
  Object? _error;
  bool _audioOnly = false;
  String? _quality;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final nowPlaying = NowPlaying.instance;

    // Bu içerik zaten çalıyorsa (ör. mini oynatıcıdan geri dönüldü): medyayı
    // YENİDEN BAŞLATMA. Konum ve kullanıcının seçtiği mod korunur.
    if (nowPlaying.isCurrent(widget.videoId)) {
      setState(() {
        _details = nowPlaying.details;
        _audioOnly = nowPlaying.audioOnly;
        _quality = nowPlaying.qualityLabel;
      });
      return;
    }

    setState(() {
      _details = null;
      _error = null;
    });
    try {
      final details = await _extraction.videoDetails(widget.videoId);
      if (!mounted) return;

      // Açılış modu içeriğin türünden belirlenir; sonrası kullanıcının.
      final audioOnly = detectContentKind(details) == ContentKind.music;
      final streams = selectStreams(details, audioOnly: audioOnly);
      if (streams == null) {
        setState(() => _error = 'Bu video için oynatılabilir kaynak bulunamadı.');
        return;
      }

      setState(() {
        _details = details;
        _audioOnly = audioOnly;
        _quality = streams.qualityLabel;
      });
      nowPlaying.start(details,
          audioOnly: audioOnly, quality: streams.qualityLabel);

      await _playback.play(
        audioUrl: streams.audioUrl,
        videoUrl: streams.videoUrl,
        title: details.title,
        artist: details.uploaderName,
        artworkUrl: details.thumbnailUrl,
        audioOnly: audioOnly,
        isLive: streams.isLive,
      );
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _toggleMode() async {
    final details = _details;
    if (details == null) return;
    final next = !_audioOnly;
    final streams = selectStreams(details, audioOnly: next);
    if (streams == null) return;

    // Konum native tarafta korunur; baştan başlamaz.
    await _playback.setAudioOnly(next);
    if (!mounted) return;
    setState(() {
      _audioOnly = next;
      _quality = streams.qualityLabel;
    });
    NowPlaying.instance
        .updateMode(audioOnly: next, quality: streams.qualityLabel);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_audioOnly ? 'Dinleniyor' : 'İzleniyor'),
        actions: [
          IconButton(
            tooltip: _audioOnly ? 'Videoya geç' : 'Sadece sese geç',
            icon: Icon(_audioOnly ? Icons.videocam_outlined : Icons.headphones),
            onPressed: _details == null ? null : _toggleMode,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Tekrar dene')),
            ],
          ),
        ),
      );
    }

    final details = _details;
    if (details == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: _audioOnly
              ? _AudioModeArtwork(details: details)
              : const VideoSurface(),
        ),
        _PlaybackControls(playback: _playback),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(details.title,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                [?details.uploaderName, ?_quality].join(' • '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_audioOnly) ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.headphones),
                    title: const Text('Sesli mod'),
                    subtitle: const Text(
                      'Video indirilmiyor. Ekrandan çıksan bile çalmaya devam eder.',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Sesli modda video yüzeyi yerine kapak görseli gösterilir — video katmanı
/// hiç oluşturulmadığı için "kazara videoya dönme" mümkün değildir.
class _AudioModeArtwork extends StatelessWidget {
  const _AudioModeArtwork({required this.details});

  final VideoDetails details;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: details.thumbnailUrl == null
          ? const Center(child: Icon(Icons.music_note, size: 48))
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.network(details.thumbnailUrl!, fit: BoxFit.cover),
                Container(color: Colors.black54),
                const Center(child: Icon(Icons.headphones, size: 48)),
              ],
            ),
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.playback});

  final PlaybackClient playback;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: playback.stateStream,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const PlaybackState();
        final duration = state.duration ?? Duration.zero;
        final maxMs = duration.inMilliseconds.toDouble();
        final positionMs =
            state.position.inMilliseconds.clamp(0, duration.inMilliseconds);

        // Canlı yayının bilinen bir süresi ve sarılabilir bir konumu yoktur;
        // ilerleme çubuğu ve atlama düğmeleri anlamsız olacağı için gizlenir.
        final isLive = state.duration == null;

        return Column(
          children: [
            if (isLive)
              const SizedBox(height: 16)
            else
              Slider(
                value: maxMs == 0 ? 0 : positionMs.toDouble(),
                max: maxMs == 0 ? 1 : maxMs,
                onChanged: maxMs == 0
                    ? null
                    : (v) =>
                        playback.seekTo(Duration(milliseconds: v.toInt())),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  if (isLive)
                    Row(
                      children: [
                        Icon(Icons.circle,
                            size: 10, color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 6),
                        const Text('CANLI'),
                      ],
                    )
                  else
                    Text(_fmt(state.position)),
                  const Spacer(),
                  if (!isLive)
                    IconButton(
                      icon: const Icon(Icons.replay_10),
                      onPressed: () => playback.seekTo(
                        state.position - const Duration(seconds: 10),
                      ),
                    ),
                  IconButton(
                    iconSize: 40,
                    icon: Icon(
                      state.isBuffering
                          ? Icons.hourglass_empty
                          : (state.playWhenReady
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled),
                    ),
                    onPressed: () => state.playWhenReady
                        ? playback.pause()
                        : playback.resume(),
                  ),
                  if (!isLive)
                    IconButton(
                      icon: const Icon(Icons.forward_10),
                      onPressed: () => playback.seekTo(
                        state.position + const Duration(seconds: 10),
                      ),
                    ),
                  const Spacer(),
                  if (!isLive) Text(_fmt(duration)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
