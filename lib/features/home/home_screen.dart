import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../library/download_progress_bar.dart';
import '../library/library_screen.dart';
import '../player/mini_player.dart';
import '../player/player_route.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import '../settings/settings_screen.dart';
import '../../core/ui/tv_mode.dart';
import '../settings/update_prompt.dart';
import 'app_title.dart';
import 'feed_tabs.dart';
import 'home_feed.dart';

/// Ana ekran: kullanıcının arama ve izleme geçmişinden üretilen kişisel akış.
///
/// Trend listesi bilerek gösterilmiyor — kullanıcı kendi ilgi alanlarını
/// görmek istiyor.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _feed = HomeFeed();
  final _library = LibraryStore.instance;

  /// Televizyonda kumandanın yukarı oku bu düğmeye çıkıyor.
  final _searchFocus = FocusNode(debugLabel: 'anaEkranArama');

  List<VideoSummary> _videos = const [];
  bool _loading = false;
  Object? _error;
  HomeTab _tab = HomeTab.forYou;

  /// Akışın hangi tohumlardan üretildiği. Kullanıcı geçmişi silince akışın
  /// yenilenmesi gerektiğini buradan anlıyoruz.
  List<FeedSeed> _feedSeeds = const [];

  /// Son yükleme ağ yüzünden başarısız oldu; yeniden denenecek.
  bool _failed = false;
  int _retries = 0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    // Önce son başarılı liste: açılışta internet yoksa ana sayfa boş kalmasın.
    _videos = _library.feedCache;
    _feedSeeds = _feed.seeds();
    _library.addListener(_onLibraryChanged);
    WidgetsBinding.instance.addObserver(this);
    _load();

    // Güncelleme denetimi açılışı geciktirmesin: ilk kare çizildikten sonra
    // arka planda sorulur, yalnızca yeni sürüm varsa pencere gelir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdatePrompt.maybeShow(context);
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _library.removeListener(_onLibraryChanged);
    _searchFocus.dispose();
    super.dispose();
  }

  /// Geçmiş silinince akışı tazele: silinen şeylerin benzerleri ana
  /// sayfada kalmamalı. YENİ bir şarkı dinlemek akışı baştan kurdurmuyor —
  /// her şarkıda liste kullanıcının elinde değişir ve beş çözümleme daha
  /// yapılırdı; yeni dinlenenler bir sonraki açılışta akışa yansıyor.
  void _onLibraryChanged() {
    if (_loading) return;
    final removed = _feedSeeds.any((seed) => !_feed.isStillInHistory(seed));
    final firstHistory = _feedSeeds.isEmpty && _feed.seeds().isNotEmpty;
    if (removed || firstHistory) _load();
  }

  /// Uygulamaya geri dönülünce başarısız kalmış akışı hemen yeniden dene.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _failed && !_loading) {
      _retries = 0;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _retryTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final seeds = _feed.seeds();
      final videos = await _feed.load();
      if (!mounted) return;
      if (videos.isNotEmpty) unawaited(_library.saveFeedCache(videos));
      setState(() {
        _videos = videos;
        _feedSeeds = seeds;
        _loading = false;
        _failed = false;
        _retries = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Önbellekten gösterilen liste varsa hata ekranı yerine o kalıyor.
        if (_videos.isEmpty) _error = e;
        _loading = false;
        _failed = true;
      });
      _scheduleRetry();
    }
  }

  /// İnternet gelince kullanıcı bir şey yapmadan dolsun: artan aralıklarla
  /// (15 sn, 30 sn, … en çok 2 dk) birkaç kez yeniden dener.
  void _scheduleRetry() {
    if (_retries >= _maxRetries) return;
    _retries++;
    final seconds = (15 * _retries).clamp(15, 120);
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && _failed) _load();
    });
  }

  static const _maxRetries = 8;

  List<VideoSummary> get _currentList =>
      _tab == HomeTab.forYou ? _videos : _library.favorites;

  void _open(int index) {
    final list = _currentList;
    final videoId = list[index].videoId!;
    PlaybackCoordinator.instance.play(videoId, context: list);
    openPlayer(context, videoId);
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SearchScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const AppTitle(),
        actions: [
          IconButton(
            focusNode: _searchFocus,
            icon: const Icon(Icons.search),
            tooltip: 'Ara',
            onPressed: _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.library_music_outlined),
            tooltip: 'Kitaplık',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LibraryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Ayarlar',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _library,
        builder: (context, _) => Column(
          children: [
            _buildTabs(),
            Expanded(child: _buildBody()),
            const DownloadProgressBar(),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    // Geçmiş de favori de yokken filtre göstermek anlamsız.
    if (!_feed.hasHistory && _library.favorites.isEmpty) {
      return const SizedBox.shrink();
    }

    final tabs = FeedTabs(
      selected: _tab,
      onChanged: (tab) => setState(() => _tab = tab),
    );

    // Televizyonda başlık çubuğuna kumandayla çıkılabilsin diye yukarı ok
    // burada yakalanıyor: Flutter'ın yönlü gezinmesi başlık çubuğuna
    // ulaşmıyor ve arama ekranı erişilemez kalıyordu.
    return Focus(
      // Bu düğüm yalnızca tuş yakalar, ODAK ALMAZ: odak alınca sekmelerin
      // kendi odağını çalıyor ve sekmeler arası sol/sağ geçiş çalışmıyordu.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (!TvMode.isTv.value) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
          return KeyEventResult.ignored;
        }
        _searchFocus.requestFocus();
        return KeyEventResult.handled;
      },
      child: tabs,
    );
  }

  Widget _buildBody() {
    if (!_feed.hasHistory && _videos.isEmpty && !_loading) {
      return _EmptyFeed(onSearch: _openSearch);
    }

    if (_tab == HomeTab.favorites) {
      return VideoList(
        videos: _library.favorites,
        loading: false,
        hasMore: false,
        onLoadMore: () {},
        onTap: _open,
        emptyMessage:
            'Henüz favorin yok.\n'
            'Çalan şarkıda ♥ simgesine dokunduğunda burada görünür.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: VideoList(
        videos: _videos,
        loading: _loading,
        hasMore: false,
        error: _error,
        onRetry: _load,
        onLoadMore: () {},
        onTap: _open,
        emptyMessage: 'Öneri bulunamadı.',
      ),
    );
  }
}

/// Geçmiş henüz boşken gösterilir: akışın neye göre dolacağını anlatır.
class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({required this.onSearch});

  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Akışın seni tanıdıkça dolacak',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Aramaların ve izlediklerin buraya benzer içerikler getirir.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onSearch,
              icon: const Icon(Icons.search),
              label: const Text('Aramaya başla'),
            ),
          ],
        ),
      ),
    );
  }
}

