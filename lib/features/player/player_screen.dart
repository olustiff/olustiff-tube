import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/data/settings_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/playback_coordinator.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import 'video_surface.dart';

/// Oynatma ekranı.
///
/// Davranış sözleşmesi:
/// - Müzik içeriği varsayılan olarak SESLİ modda açılır, video içeriği video
///   modunda. Bu tespit yalnızca açılışta yapılır.
/// - Kullanıcı modu elle değiştirebilir; seçtiği mod kendiliğinden geri
///   dönmez.
/// - Sesli moddayken video yüzeyi hiç oluşturulmaz ve video parçası hiç
///   indirilmez.
///
/// Ekran, oynatmanın sahibi DEĞİLDİR: kuyruk ve otomatik geçiş native tarafta
/// yaşar, bu yüzden ekran kapansa (hatta telefon kilitlense) bile sıradakine
/// geçilir.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.videoId});

  final String videoId;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _coordinator = PlaybackCoordinator.instance;
  final _playback = PlaybackClient.shared;

  Object? _error;

  @override
  void initState() {
    super.initState();
    if (!_coordinator.isCurrent(widget.videoId)) _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      await _coordinator.play(widget.videoId);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _addToPlaylist() async {
    final details = _coordinator.details;
    if (details == null) return;
    final store = LibraryStore.instance;

    final name = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Çalma listesine ekle')),
              for (final name in store.playlists.keys)
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(name),
                  onTap: () => Navigator.of(context).pop(name),
                ),
              if (store.playlists.isEmpty)
                const ListTile(
                  subtitle: Text('Önce Kitaplık\'tan bir liste oluştur.'),
                ),
            ],
          ),
        ),
      ),
    );

    if (name == null) return;
    await store.addToPlaylist(
      name,
      VideoSummary(
        videoId: details.videoId,
        title: details.title,
        url: 'https://www.youtube.com/watch?v=${details.videoId}',
        uploaderName: details.uploaderName,
        durationSeconds: details.durationSeconds,
        viewCount: details.viewCount,
        textualUploadDate: null,
        thumbnailUrl: details.thumbnailUrl,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('"$name" listesine eklendi')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _coordinator,
      builder: (context, _) {
        final details = _coordinator.details;
        final audioOnly = _coordinator.audioOnly;

        return Scaffold(
          appBar: AppBar(
            title: Text(audioOnly ? 'Dinleniyor' : 'İzleniyor'),
            actions: [
              // Yeni bir şey aramak için listeye geri dönmek gerekmiyor.
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Ara',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.playlist_add),
                tooltip: 'Listeye ekle',
                onPressed: details == null ? null : _addToPlaylist,
              ),
              IconButton(
                tooltip: audioOnly ? 'Videoya geç' : 'Sadece sese geç',
                icon: Icon(
                    audioOnly ? Icons.videocam_outlined : Icons.headphones),
                onPressed: details == null ? null : _coordinator.toggleMode,
              ),
            ],
          ),
          body: _buildBody(details, audioOnly),
        );
      },
    );
  }

  Widget _buildBody(VideoDetails? details, bool audioOnly) {
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
              FilledButton(onPressed: _start, child: const Text('Tekrar dene')),
            ],
          ),
        ),
      );
    }

    if (details == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamBuilder<PlaybackState>(
      stream: _playback.stateStream,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const PlaybackState();

        return Column(
          children: [
            AspectRatio(
              aspectRatio: audioOnly ? 16 / 9 : state.aspectRatio,
              child: audioOnly
                  ? _AudioModeArtwork(details: details)
                  : const VideoSurface(),
            ),
            _PlaybackControls(
              state: state,
              playback: _playback,
              coordinator: _coordinator,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  Text(details.title,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    [?details.uploaderName, ?_coordinator.qualityLabel]
                        .join(' • '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  _QuickSettings(state: state),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.playlist_play),
                    title: const Text('Otomatik oynatma'),
                    subtitle: Text(
                      _coordinator.upNext == null
                          ? 'Bittiğinde durur.'
                          : 'Sırada: ${_coordinator.upNext!.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: state.autoplay,
                    onChanged: _coordinator.setAutoplay,
                  ),
                  if (audioOnly)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.headphones),
                        title: Text('Sesli mod'),
                        subtitle: Text(
                          'Video indirilmiyor. Ekrandan çıksan bile çalmaya devam eder.',
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  _QueueSection(coordinator: _coordinator),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Oynatıcı içinden hız ve kalite değiştirme — ayarlara gitmeye gerek yok.
class _QuickSettings extends StatelessWidget {
  const _QuickSettings({required this.state});

  final PlaybackState state;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => Row(
        children: [
          const Icon(Icons.speed, size: 18),
          const SizedBox(width: 8),
          DropdownButton<double>(
            value: settings.speed,
            underline: const SizedBox.shrink(),
            onChanged: (value) async {
              if (value == null) return;
              await settings.setSpeed(value);
              await PlaybackClient.shared.setSpeed(value);
            },
            items: [
              for (final option in SettingsStore.speedOptions)
                DropdownMenuItem(value: option, child: Text('${option}x')),
            ],
          ),
          const Spacer(),
          const Icon(Icons.high_quality_outlined, size: 18),
          const SizedBox(width: 8),
          DropdownButton<int?>(
            value: settings.maxHeight,
            underline: const SizedBox.shrink(),
            // Kalite değişimi bir sonraki videoda geçerli olur; mevcut akışı
            // yeniden kurmak oynatmayı kesintiye uğratırdı.
            onChanged: settings.setMaxHeight,
            items: [
              for (final option in SettingsStore.qualityOptions)
                DropdownMenuItem(
                  value: option,
                  child: Text(option == null ? 'En yüksek' : '${option}p'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Sırada çalacaklar. Kuyruk, videoya hangi listeden girildiyse ondan ve
/// ilgili videolardan karıştırılarak kurulur (bkz. QueueBuilder).
class _QueueSection extends StatelessWidget {
  const _QueueSection({required this.coordinator});

  final PlaybackCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final queue = coordinator.queue;
    final start = coordinator.queueIndex + 1;
    if (start >= queue.length) return const SizedBox.shrink();

    final upcoming = queue.sublist(start);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sırada', style: Theme.of(context).textTheme.titleSmall),
        for (var i = 0; i < upcoming.length; i++)
          VideoTile(
            video: upcoming[i],
            onTap: () => coordinator.playQueueIndex(start + i),
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
  const _PlaybackControls({
    required this.state,
    required this.playback,
    required this.coordinator,
  });

  final PlaybackState state;
  final PlaybackClient playback;
  final PlaybackCoordinator coordinator;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final duration = state.duration ?? Duration.zero;
    final maxMs = duration.inMilliseconds.toDouble();
    final positionMs =
        state.position.inMilliseconds.clamp(0, duration.inMilliseconds);

    // Canlı yayının bilinen bir süresi ve sarılabilir bir konumu yoktur.
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
                : (v) => playback.seekTo(Duration(milliseconds: v.toInt())),
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
              IconButton(
                icon: const Icon(Icons.skip_previous),
                tooltip: 'Önceki',
                onPressed: state.hasPrevious ? coordinator.playPrevious : null,
              ),
              if (!isLive)
                IconButton(
                  icon: const Icon(Icons.replay_10),
                  onPressed: () => playback
                      .seekTo(state.position - const Duration(seconds: 10)),
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
                onPressed: () =>
                    state.playWhenReady ? playback.pause() : playback.resume(),
              ),
              if (!isLive)
                IconButton(
                  icon: const Icon(Icons.forward_10),
                  onPressed: () => playback
                      .seekTo(state.position + const Duration(seconds: 10)),
                ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                tooltip: 'Sonraki',
                onPressed: state.hasNext ? coordinator.playNext : null,
              ),
              const Spacer(),
              if (!isLive) Text(_fmt(duration)),
            ],
          ),
        ),
      ],
    );
  }
}
