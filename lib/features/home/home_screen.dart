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

class _HomeScreenState extends State<HomeScreen> {
  final _feed = HomeFeed();
  final _library = LibraryStore.instance;

  /// Televizyonda kumandanın yukarı oku bu düğmeye çıkıyor.
  final _searchFocus = FocusNode(debugLabel: 'anaEkranArama');

  List<VideoSummary> _videos = const [];
  bool _loading = false;
  Object? _error;
  HomeTab _tab = HomeTab.forYou;

  /// Akışın hangi aramalardan üretildiği. Kullanıcı bir aramayı silince
  /// akışın yenilenmesi gerektiğini buradan anlıyoruz.
  List<String> _feedSeeds = const [];

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibraryChanged);
    _load();

    // Güncelleme denetimi açılışı geciktirmesin: ilk kare çizildikten sonra
    // arka planda sorulur, yalnızca yeni sürüm varsa pencere gelir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdatePrompt.maybeShow(context);
    });
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    _searchFocus.dispose();
    super.dispose();
  }

  /// Arama geçmişi değişince akışı tazele: silinen bir aramanın sonuçları
  /// ana sayfada kalmamalı.
  void _onLibraryChanged() {
    if (_loading) return;
    final seeds = _feed.seeds();
    final changed = seeds.length != _feedSeeds.length ||
        !seeds.every(_feedSeeds.contains);
    if (changed) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final seeds = _feed.seeds();
      final videos = await _feed.load();
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _feedSeeds = seeds;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  List<VideoSummary> get _currentList =>
      _tab == HomeTab.forYou ? _videos : _library.mostPlayed;

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
    if (!_feed.hasHistory && _library.mostPlayed.isEmpty) {
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
        videos: _library.mostPlayed,
        loading: false,
        hasMore: false,
        onLoadMore: () {},
        onTap: _open,
        emptyMessage:
            'Henüz tekrar dinlediğin bir şey yok.\n'
            'Bir şarkıyı ikinci kez açtığında burada görünür.',
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

