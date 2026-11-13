import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/cast/youtube_cast_controller.dart';
import '../../core/data/library_store.dart';
import '../../core/data/settings_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/playback/sleep_timer.dart';
import '../../core/ui/tv_mode.dart';
import '../../core/playback/ui_channel.dart';
import '../library/download_progress_bar.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import 'cast_button.dart';
import 'cast_panel.dart';
import 'double_tap_seek.dart';
import 'download_menu.dart';
import 'favorite_button.dart';
import 'quality_menu.dart';
import 'tv_player.dart';
import 'video_player_view.dart';
import 'youtube_cast_panel.dart';
import '../../core/i18n/lang.dart';

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

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  final _coordinator = PlaybackCoordinator.instance;
  final _playback = PlaybackClient.shared;

  @override
  void initState() {
    super.initState();
    if (!_coordinator.isCurrent(widget.videoId)) _start();
    _applyKeepScreenOn();
    _coordinator.addListener(_applyKeepScreenOn);
    CastController.instance.addListener(_showCastError);
    YouTubeCastController.instance.addListener(_showYouTubeCastError);
    if (TvMode.isTv.value) WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _coordinator.removeListener(_applyKeepScreenOn);
    CastController.instance.removeListener(_showCastError);
    YouTubeCastController.instance.removeListener(_showYouTubeCastError);
    // Ekran kısıtı yalnızca video izlerken geçerli olmalı.
    UiChannel.instance.setKeepScreenOn(false);
    if (TvMode.isTv.value) {
      WidgetsBinding.instance.removeObserver(this);
      // Televizyonda "arka planda çalma" diye bir senaryo yok: ekran karşıda
      // ve kullanıcı çıktığında sesin sürmesi hata gibi duruyor. TELEFONDA
      // tam tersi geçerli — orada oynatma bilerek sürdürülüyor.
      _coordinator.stop();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Televizyonda uygulamadan çıkılınca (ana ekran tuşu, başka uygulama)
    // oynatma sürmemeli. `inactive` sayılmıyor: o durum kısa süreli ve
    // uygulama hâlâ görünür olabiliyor.
    if (!TvMode.isTv.value) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (UiChannel.instance.isInPictureInPicture.value) return;
      _coordinator.stop();
    }
  }

  /// Yayınla ilgili hatayı bir kez gösterir.
  ///
  /// Tek yerden gösteriliyor: televizyon bağlantısı kopabilir, gönderim
  /// başarısız olabilir, komut gidemeyebilir — hepsi aynı yerden geçiyor ve
  /// kullanıcı ölü bir kumandayla sessizce baş başa kalmıyor.
  void _showCastError() {
    final error = CastController.instance.lastError;
    if (error == null || !mounted) return;
    CastController.instance.clearError();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  /// Televizyonun kendi YouTube'una gönderirken oluşan hatayı gösterir.
  ///
  /// Ayrı bir yöntem çünkü hatanın kaynağı ayrı bir denetleyici; tek bir
  /// dinleyiciye bağlamak hangi yayının koptuğunu belirsizleştirirdi.
  void _showYouTubeCastError() {
    final cast = YouTubeCastController.instance;
    final error = cast.lastError;
    if (error == null || !mounted) return;
    cast.clearError();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
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
              ListTile(title: Text(tr('Çalma listesine ekle', 'Add to playlist'))),
              // Liste yoksa kullanıcıyı başka ekrana göndermeden buradan
              // oluşturmasına izin ver.
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(tr('Yeni liste oluştur', 'Create new playlist')),
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
                  subtitle: Text(tr('${store.playlists[name]!.length} video', store.playlists[name]!.length == 1 ? '1 video' : '${store.playlists[name]!.length} videos')),
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
      ).showSnackBar(SnackBar(content: Text(tr('"$selected" listesine eklendi', 'Added to "$selected"'))));
    }
  }

  Future<String?> _promptPlaylistName(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Yeni çalma listesi', 'New playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('Liste adı', 'Playlist name')),
          onSubmitted: (v) =>
              Navigator.of(context).pop(v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Vazgeç', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.of(context).pop(value.isEmpty ? null : value);
            },
            child: Text(tr('Oluştur', 'Create')),
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
            ListTile(title: Text(tr('Uyku zamanlayıcısı', 'Sleep timer'))),
            for (final option in SleepTimer.options)
              ListTile(
                leading: const Icon(Icons.bedtime_outlined),
                title: Text(
                  option.inHours > 0
                      ? tr('${option.inHours} saat', option.inHours == 1 ? '1 hour' : '${option.inHours} hours')
                      : tr('${option.inMinutes} dakika', '${option.inMinutes} minutes'),
                ),
                onTap: () {
                  timer.start(option);
                  Navigator.of(context).pop();
                },
              ),
            if (timer.isActive)
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(tr('Zamanlayıcıyı iptal et', 'Cancel timer')),
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

  /// Mod değişimi ONAYLA yapılıyor: seçim sonraki videolara da geçtiği
  /// için (bkz. SettingsStore.lastAudioOnly) yanlışlıkla bir dokunuş
  /// bundan sonraki her şeyi değiştirirdi.
  Future<void> _confirmToggleMode() async {
    final toVideo = _coordinator.audioOnly;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(toVideo ? tr('Video moduna geçilsin mi?', 'Switch to video mode?') : tr('Sesli moda geçilsin mi?', 'Switch to audio mode?')),
        content: Text(
          toVideo
              ? tr('Görüntü de indirilecek. Bundan sonra açtıkların da video olarak başlar.', 'Video will be streamed too. Videos you open from now on will also start in video mode.')
              : tr(
                  'Yalnızca ses çalar, internet ve pil tasarrufu sağlar. '
                      'Bundan sonra açtıkların da sesli başlar.',
                  'Plays audio only, saving data and battery. '
                      'Videos you open from now on will also start in audio mode.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Vazgeç', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(toVideo ? tr('Videoya geç', 'Switch to video') : tr('Sesliye geç', 'Switch to audio')),
          ),
        ],
      ),
    );
    if (ok == true) await _coordinator.toggleMode();
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

  /// Tuş kısayolları oynatmayı çalanın ÜZERİNDE uygulamalı: yayın açıkken
  /// televizyonda, kapalıyken telefonda. Doğrudan yerel oynatıcıya gitmek,
  /// televizyon çalarken telefonda ikinci bir ses başlatıyordu.
  Future<void> _togglePlay() async {
    final cast = CastController.instance;
    final playing = cast.isCasting
        ? (cast.remoteState?.isPlaying ?? false)
        : (_lastState?.playWhenReady ?? false);
    if (playing) {
      await _coordinator.pause();
    } else {
      await _coordinator.resume();
    }
  }

  Future<void> _seekRelative(Duration offset) async {
    final cast = CastController.instance;
    final position = cast.isCasting
        ? (cast.remoteState?.position ?? Duration.zero)
        : (_lastState?.position ?? Duration.zero);
    await _coordinator.seekBy(offset, position);
  }

  /// Kısayolların o anki konumu/durumu bilmesi için son durum saklanır.
  PlaybackState? _lastState;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: UiChannel.instance.isInPictureInPicture,
      builder: (context, pip, _) => AnimatedBuilder(
        // Yayın (cast) açılıp kapandığında ekranın tamamı değişiyor:
        // oynatıcı yerini televizyon kumandasına bırakıyor.
        animation: Listenable.merge([
          _coordinator,
          CastController.instance,
          // Televizyonun kendi YouTube'una geçildiğinde de ekran kumandaya
          // dönmeli; bu denetleyici dinlenmezse değişiklik fark edilmiyor.
          YouTubeCastController.instance,
        ]),
        builder: (context, _) {
          // Televizyonda oynatma tam ekran ve tuş haritası [TvPlayer]'a ait.
          // Buradaki kısayollar ve odak düğümü ona KARIŞMAMALI: ikisi de
          // ok tuşlarını isteyince sarma iki kez uygulanıyordu.
          if (TvMode.isTv.value && !pip) {
            return TvPlayer(
              details: _coordinator.details,
              playback: _playback,
              coordinator: _coordinator,
            );
          }
          return CallbackShortcuts(
            bindings: _shortcuts(),
            child: Focus(
              autofocus: true,
              child: _buildScreen(context, pip),
            ),
          );
        },
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
              title: Text(
                CastController.instance.isCasting
                    ? tr("TV'de oynatılıyor", 'Playing on TV')
                    : (audioOnly ? tr('Dinleniyor', 'Listening') : tr('İzleniyor', 'Watching')),
              ),
              actions: [
                // Televizyona gönderme yalnızca çalacak bir şey varken
                // anlamlı; hazırlık sürerken gönderilecek video henüz belli
                // değil.
                if (details != null)
                  CastButton(
                    positionOf: () => _lastState?.position ?? Duration.zero,
                  ),
                // Yeni bir şey aramak için listeye geri dönmek gerekmiyor.
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: tr('Ara', 'Search'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SearchScreen()),
                  ),
                ),
                // Yayın açıkken ses/video seçimi televizyonun işi; telefonda
                // göstermek hem anlamsız hem de başlığı kısaltacak kadar yer
                // kaplıyordu.
                if (!CastController.instance.isCasting)
                  IconButton(
                    tooltip: audioOnly ? tr('Videoya geç', 'Switch to video') : tr('Sadece sese geç', 'Switch to audio only'),
                    icon: Icon(
                      audioOnly ? Icons.videocam_outlined : Icons.headphones,
                    ),
                    onPressed: details == null ? null : _confirmToggleMode,
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
                    PopupMenuItem(
                      value: 'download',
                      child: ListTile(
                        leading: const Icon(Icons.download_outlined),
                        title: Text(tr('MP3 indir', 'Download MP3')),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'sleep',
                      child: ListTile(
                        leading: const Icon(Icons.bedtime_outlined),
                        title: Text(
                          SleepTimer.instance.isActive
                              ? tr('Uyku zamanlayıcısı (açık)', 'Sleep timer (on)')
                              : tr('Uyku zamanlayıcısı', 'Sleep timer'),
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        leading: const Icon(Icons.share_outlined),
                        title: Text(tr('Paylaş', 'Share')),
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
    // Yayın açıkken video televizyonda: telefonda oynatıcı değil kumanda
    // gösterilir. Yerel oynatma [CastController] tarafından duraklatıldı,
    // burada ayrıca durdurulmuyor.
    final cast = CastController.instance;
    if (cast.isCasting) {
      return SingleChildScrollView(
        child: CastPanel(
          title: details?.title ?? cast.remoteState?.title ?? '',
          thumbnailUrl: details?.thumbnailUrl,
          videoId: details?.videoId ?? cast.remoteState?.videoId,
        ),
      );
    }

    // Televizyonun KENDİ YouTube'una gönderiliyorsa ayrı bir kumanda
    // gösteriliyor: orada konum/süre okunamadığı için sunulan kontroller
    // farklı (bkz. YouTubeCastPanel).
    if (YouTubeCastController.instance.isCasting) {
      return const SingleChildScrollView(child: YouTubeCastPanel());
    }

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
              FilledButton(onPressed: _start, child: Text(tr('Tekrar dene', 'Try again'))),
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              details.title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                        FavoriteButton(coordinator: _coordinator),
                      ],
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
                      title: Text(tr('Otomatik oynatma', 'Autoplay')),
                      subtitle: Text(
                        _coordinator.upNext == null
                            ? tr('Bittiğinde durur.', 'Stops when finished.')
                            : tr('Sırada: ${_coordinator.upNext!.title}', 'Up next: ${_coordinator.upNext!.title}'),
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
              'one' => tr('Tek parçayı tekrarla', 'Repeat one'),
              'all' => tr('Listeyi tekrarla', 'Repeat all'),
              _ => tr('Tekrar kapalı', 'Repeat off'),
            },
            onPressed: () => coordinator.setRepeatMode(_nextRepeatMode),
          ),
          IconButton(
            icon: Icon(
              state.shuffle ? Icons.shuffle_on_outlined : Icons.shuffle,
            ),
            tooltip: state.shuffle ? tr('Karıştırma açık', 'Shuffle on') : tr('Karıştır', 'Shuffle'),
            onPressed: () => coordinator.setShuffle(!state.shuffle),
          ),
          // Menünün içinde kaybolmak yerine diğer kuyruk kontrolleriyle
          // birlikte dursun.
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: tr('Çalma listesine ekle', 'Add to playlist'),
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
    // Gerçek çalma sırası: karıştırma açıkken kuyruğun kendi sırası DEĞİL.
    final upcoming = coordinator.upcoming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Sırada', 'Up next'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (upcoming.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(tr('Sırada başka video yok.', 'No more videos in the queue.')),
          )
        else
          for (final item in upcoming)
            VideoTile(
              video: item.video,
              onTap: () => coordinator.playQueueIndex(item.index),
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
                    Text(tr('CANLI', 'LIVE')),
                  ],
                )
              else if (showSeek)
                Text(_fmt(state.position)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.skip_previous),
                tooltip: tr('Önceki', 'Previous'),
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
                tooltip: tr('Sonraki', 'Next'),
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
