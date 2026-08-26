import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/data/library_store.dart';
import '../../core/data/settings_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/playback/sleep_timer.dart';
import '../../core/playback/ui_channel.dart';
import '../library/download_progress_bar.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import 'double_tap_seek.dart';
import 'download_menu.dart';
import 'quality_menu.dart';
import 'video_player_view.dart';

/// Oynatma ekranı.
///
/// Davranış sözleşmesi:
/// - Müzik içeriği varsayılan olarak SESLİ modda açılır, video içeriği video
///   modunda. Bu tespit yalnızca açılışta yapılır.
/// - Kullanıcı modu elle değiştirebilir; seçtiği mod kendiliğinden geri dönmez.
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

  @override
  void initState() {
    super.initState();
    if (!_coordinator.isCurrent(widget.videoId)) _start();
    _applyKeepScreenOn();
    _coordinator.addListener(_applyKeepScreenOn);
  }

  @override
  void dispose() {
    _coordinator.removeListener(_applyKeepScreenOn);
    // Ekran kısıtı yalnızca video izlerken geçerli olmalı.
    UiChannel.instance.setKeepScreenOn(false);
    super.dispose();
  }

  /// Video izlenirken ekran kapanmasın; sesli modda telefon normal uyusun.
  void _applyKeepScreenOn() {
    UiChannel.instance.setKeepScreenOn(!_coordinator.audioOnly);
  }

  Future<void> _start() => _coordinator.play(widget.videoId);

  Future<void> _openFullscreen() async {
    // Tam ekran = yatay + sistem çubukları gizli.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullscreenPlayerPage(playback: _playback),
      ),
    );

    // Geri dönüldüğünde dikey düzen ve çubuklar geri gelsin.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  Future<void> _addToPlaylist() async {
    final details = _coordinator.details;
    if (details == null) return;
    final store = LibraryStore.instance;

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => AnimatedBuilder(
        animation: store,
        builder: (context, _) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Çalma listesine ekle')),
              // Liste yoksa kullanıcıyı başka ekrana göndermeden buradan
              // oluşturmasına izin ver.
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Yeni liste oluştur'),
                onTap: () async {
                  final name = await _promptPlaylistName(sheetContext);
                  if (name == null) return;
                  await store.createPlaylist(name);
                  if (sheetContext.mounted) {
                    Navigator.of(sheetContext).pop(name);
                  }
                },
              ),
              if (store.playlists.isNotEmpty) const Divider(height: 1),
              for (final name in store.playlists.keys)
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(name),
                  subtitle: Text('${store.playlists[name]!.length} video'),
                  onTap: () => Navigator.of(sheetContext).pop(name),
                ),
            ],
          ),
        ),
      ),
    );

    if (selected == null) return;
    await store.addToPlaylist(
      selected,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('"$selected" listesine eklendi')));
    }
  }

  Future<String?> _promptPlaylistName(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeni çalma listesi'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Liste adı'),
          onSubmitted: (v) =>
              Navigator.of(context).pop(v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.of(context).pop(value.isEmpty ? null : value);
            },
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSleepTimer() async {
    final timer = SleepTimer.instance;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Uyku zamanlayıcısı')),
            for (final option in SleepTimer.options)
              ListTile(
                leading: const Icon(Icons.bedtime_outlined),
                title: Text(
                  option.inHours > 0
                      ? '${option.inHours} saat'
                      : '${option.inMinutes} dakika',
                ),
                onTap: () {
                  timer.start(option);
                  Navigator.of(context).pop();
                },
              ),
            if (timer.isActive)
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Zamanlayıcıyı iptal et'),
                onTap: () {
                  timer.cancel();
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _share() {
    final details = _coordinator.details;
    if (details == null) return;
    SharePlus.instance.share(
      ShareParams(
        text: 'https://www.youtube.com/watch?v=${details.videoId}',
        subject: details.title,
      ),
    );
  }

  /// Kumanda ve klavye kısayolları.
  ///
  /// Televizyonda dokunma yok: oynat/duraklat ve sarma yalnızca tuşlarla
  /// yapılabiliyor. Aynı kısayollar klavyeli cihazlarda da çalışır.
  Map<ShortcutActivator, VoidCallback> _shortcuts() => {
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.mediaPlay): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.mediaPause): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seekRelative(const Duration(seconds: 10)),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekRelative(const Duration(seconds: -10)),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext):
            _coordinator.playNext,
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious):
            _coordinator.playPrevious,
      };

  Future<void> _togglePlay() async {
    final playing = _lastState?.playWhenReady ?? false;
    if (playing) {
      await _playback.pause();
    } else {
      await _playback.resume();
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final position = _lastState?.position ?? Duration.zero;
    final target = position + offset;
    await _playback.seekTo(target < Duration.zero ? Duration.zero : target);
  }

  /// Kısayolların o anki konumu/durumu bilmesi için son durum saklanır.
  PlaybackState? _lastState;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _shortcuts(),
      child: Focus(
        autofocus: true,
        child: ValueListenableBuilder<bool>(
          valueListenable: UiChannel.instance.isInPictureInPicture,
          builder: (context, pip, _) => AnimatedBuilder(
            animation: _coordinator,
            builder: (context, _) => _buildScreen(context, pip),
          ),
        ),
      ),
    );
  }

  Widget _buildScreen(BuildContext context, bool pip) {
    final details = _coordinator.details;
    final audioOnly = _coordinator.audioOnly;

    return Scaffold(
      // Küçük pencerede yalnızca görüntü kalır: başlık çubuğu, listeler
      // ve düğmeler o boyutta okunaksız. Oynat/duraklat'ı sistem kendi
      // düğmesiyle veriyor.
      appBar: pip
          ? null
          : AppBar(
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
                  tooltip: audioOnly ? 'Videoya geç' : 'Sadece sese geç',
                  icon: Icon(
                    audioOnly ? Icons.videocam_outlined : Icons.headphones,
                  ),
                  onPressed: details == null ? null : _coordinator.toggleMode,
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'download':
                        showDownloadMenu(context);
                      case 'sleep':
                        _openSleepTimer();
                      case 'share':
                        _share();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'download',
                      child: ListTile(
                        leading: Icon(Icons.download_outlined),
                        title: Text('MP3 indir'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'sleep',
                      child: ListTile(
                        leading: const Icon(Icons.bedtime_outlined),
                        title: Text(
                          SleepTimer.instance.isActive
                              ? 'Uyku zamanlayıcısı (açık)'
                              : 'Uyku zamanlayıcısı',
                        ),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        leading: Icon(Icons.share_outlined),
                        title: Text('Paylaş'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
      body: _buildBody(details, audioOnly, pip),
    );
  }

  Widget _buildBody(VideoDetails? details, bool audioOnly, bool pip) {
    final error = _coordinator.lastError;
    if (error != null && details == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _start, child: const Text('Tekrar dene')),
            ],
          ),
        ),
      );
    }

    if (details == null) {
      // Yeni medya hazırlanıyor: eski videonun karesi yerine, dokunulan
      // içeriğin başlığıyla birlikte yükleme durumu gösterilir.
      return _PreparingView(
        pending: _coordinator.pending,
        loading: _coordinator.isLoading,
      );
    }

    return StreamBuilder<PlaybackState>(
      stream: _playback.stateStream,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const PlaybackState();
        _lastState = state;

        return Column(
          children: [
            AspectRatio(
              aspectRatio: audioOnly ? 16 / 9 : state.aspectRatio,
              child: audioOnly
                  ? DoubleTapSeek(
                      state: state,
                      playback: _playback,
                      // Süre bilinmiyorsa içerik canlı: sarma yapılmaz.
                      enabled: !state.isLive,
                      child: _AudioModeArtwork(
                        details: details,
                        isBuffering: state.isBuffering,
                      ),
                    )
                  : VideoPlayerView(
                      state: state,
                      playback: _playback,
                      isFullscreen: false,
                      pipMode: pip,
                      onToggleFullscreen: _openFullscreen,
                      posterUrl: details.thumbnailUrl,
                      onEnterPip: () =>
                          UiChannel.instance.enterPictureInPicture(),
                    ),
            ),
            // Küçük pencerede yalnızca görüntü kalsın. Video yüzeyi ağaçta
            // AYNI yerde duruyor: yerinden oynatmak native yüzeyi kopardığı
            // için pencere siyah kalırdı.
            if (!pip)
              _TransportBar(
                state: state,
                playback: _playback,
                coordinator: _coordinator,
                showSeek: audioOnly,
              ),
            if (!pip)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Text(
                      details.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        ?details.uploaderName,
                        ?_coordinator.qualityLabel,
                      ].join(' • '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    _QuickSettings(
                      state: state,
                      coordinator: _coordinator,
                      onAddToPlaylist: _addToPlaylist,
                    ),
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
                    const SizedBox(height: 8),
                    _QueueSection(coordinator: _coordinator),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            // İndirme buradan başlatılıyor; ilerlemenin de burada görünmesi
            // gerekiyor, yoksa "indiriyor mu?" belirsiz kalıyor.
            if (!pip) const DownloadProgressBar(),
          ],
        );
      },
    );
  }
}

/// Hız, kalite, tekrar, karıştır ve listeye ekle — oynatıcıdan çıkmadan.
class _QuickSettings extends StatelessWidget {
  const _QuickSettings({
    required this.state,
    required this.coordinator,
    required this.onAddToPlaylist,
  });

  final PlaybackState state;
  final PlaybackCoordinator coordinator;

  // Listeye ekleme akışı ekranın state'inde yaşıyor (sheet + kayıt), o yüzden
  // buraya geri çağrı olarak geliyor.
  final VoidCallback onAddToPlaylist;

  IconData get _repeatIcon => switch (state.repeatMode) {
    'one' => Icons.repeat_one,
    'all' => Icons.repeat_on_outlined,
    _ => Icons.repeat,
  };

  String get _nextRepeatMode => switch (state.repeatMode) {
    'off' => 'all',
    'all' => 'one',
    _ => 'off',
  };

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          const Icon(Icons.speed, size: 18),
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
          const SizedBox(width: 8),
          // Seçenekler videonun gerçek çözünürlüklerinden gelir ve seçim
          // çalan videoya hemen uygulanır (konum korunur).
          TextButton.icon(
            icon: const Icon(Icons.high_quality_outlined, size: 18),
            label: Text(coordinator.qualityLabel ?? settings.qualityLabel),
            onPressed: () => showQualityMenu(context),
          ),
          IconButton(
            icon: Icon(_repeatIcon),
            tooltip: switch (state.repeatMode) {
              'one' => 'Tek parçayı tekrarla',
              'all' => 'Listeyi tekrarla',
              _ => 'Tekrar kapalı',
            },
            onPressed: () => coordinator.setRepeatMode(_nextRepeatMode),
          ),
          IconButton(
            icon: Icon(
              state.shuffle ? Icons.shuffle_on_outlined : Icons.shuffle,
            ),
            tooltip: state.shuffle ? 'Karıştırma açık' : 'Karıştır',
            onPressed: () => coordinator.setShuffle(!state.shuffle),
          ),
          // Menünün içinde kaybolmak yerine diğer kuyruk kontrolleriyle
          // birlikte dursun.
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Çalma listesine ekle',
            onPressed: onAddToPlaylist,
          ),
        ],
      ),
    );
  }
}

/// Sırada çalacaklar ve kuyruğun nasıl kurulacağı.
class _QueueSection extends StatelessWidget {
  const _QueueSection({required this.coordinator});

  final PlaybackCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final queue = coordinator.queue;
    final start = coordinator.queueIndex + 1;
    final upcoming = start < queue.length ? queue.sublist(start) : const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sırada', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        // Dar ekranlarda tek satıra sığmadığı için başlığın altına alındı;
        // Row içinde kalsaydı segmentler kırpılıyordu.
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<QueueMode>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: QueueMode.listOrder,
                icon: Icon(Icons.format_list_numbered),
                label: Text('Aramaya göre'),
              ),
              ButtonSegment(
                value: QueueMode.mixed,
                icon: Icon(Icons.shuffle),
                label: Text('Karışık'),
              ),
            ],
            selected: {coordinator.queueMode},
            onSelectionChanged: (selection) =>
                coordinator.setQueueMode(selection.first),
          ),
        ),
        const SizedBox(height: 8),
        if (upcoming.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Sırada başka video yok.'),
          )
        else
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
  const _AudioModeArtwork({required this.details, required this.isBuffering});

  final VideoDetails details;
  final bool isBuffering;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (details.thumbnailUrl != null)
            Image.network(details.thumbnailUrl!, fit: BoxFit.cover),
          Container(color: Colors.black54),
          Center(
            child: isBuffering
                // Yükleme göstergesi kapağın üstünde; kontrol butonunda
                // ayrıca dönmesine gerek yok.
                ? const SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.headphones, size: 48),
          ),
        ],
      ),
    );
  }
}

/// Önceki/sonraki ve oynat-duraklat. Videoda ilerleme çubuğu görüntünün
/// üstünde olduğu için burada yalnızca sesli modda gösterilir.
class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.state,
    required this.playback,
    required this.coordinator,
    required this.showSeek,
  });

  final PlaybackState state;
  final PlaybackClient playback;
  final PlaybackCoordinator coordinator;
  final bool showSeek;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final duration = state.duration;
    // Süre yokluğuna bakmak, video geçişlerinde kısa süre "CANLI" rozeti
    // yakıyordu; gerçek bilgi oynatıcıdan geliyor.
    final isLive = state.isLive;
    final maxMs = (duration ?? Duration.zero).inMilliseconds.toDouble();
    final positionMs = state.position.inMilliseconds.clamp(
      0,
      (duration ?? Duration.zero).inMilliseconds,
    );

    return Column(
      children: [
        if (showSeek && !isLive)
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
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    const Text('CANLI'),
                  ],
                )
              else if (showSeek)
                Text(_fmt(state.position)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.skip_previous),
                tooltip: 'Önceki',
                onPressed: state.hasPrevious ? coordinator.playPrevious : null,
              ),
              // Yükleme göstergesi görüntü/kapak alanında gösterildiği için
              // burada ayrıca dönmez; buton hep oynat/duraklat kalır.
              IconButton(
                iconSize: 40,
                icon: Icon(
                  state.playWhenReady
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                ),
                onPressed: () =>
                    state.playWhenReady ? playback.pause() : playback.resume(),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                tooltip: 'Sonraki',
                onPressed: state.hasNext ? coordinator.playNext : null,
              ),
              const Spacer(),
              // Süre henüz gelmemiş olabilir (yeni medya hazırlanırken).
              if (showSeek && !isLive && duration != null) Text(_fmt(duration)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Yeni medya hazırlanırken gösterilir.
///
/// Eski videonun son karesini ekranda bırakmak "tıkladım ama bir şey olmadı"
/// hissi veriyordu; burada dokunulan içeriğin kapağı ve başlığı hemen görünür.
class _PreparingView extends StatelessWidget {
  const _PreparingView({required this.pending, required this.loading});

  final VideoSummary? pending;

  /// Hazırlık sürüyor mu. Bitmiş ama detay gelmemişse (ağ hatası) dönen
  /// halkayı göstermek "takıldı" izlenimi veriyordu.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final video = pending;

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (video?.thumbnailUrl != null)
                Image.network(video!.thumbnailUrl!, fit: BoxFit.cover)
              else
                ColoredBox(color: Theme.of(context).colorScheme.surfaceDim),
              Container(color: Colors.black54),
              if (loading)
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
          ),
        ),
        if (video != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  video.uploaderName ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
