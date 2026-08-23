import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../library/library_screen.dart';
import '../player/mini_player.dart';
import '../player/player_route.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import '../settings/settings_screen.dart';
import 'home_feed.dart';

/// Ana sayfadaki liste türü.
enum HomeTab {
  /// Aramalardan ve izlenenlerden üretilen kişisel akış.
  forYou,

  /// Geçmişte en çok tekrar edilenler.
  mostPlayed,
}

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
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
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
        title: const Text('Akış'),
        actions: [
          IconButton(
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
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    // Geçmiş yokken filtre göstermek anlamsız.
    if (!_feed.hasHistory) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<HomeTab>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(
              value: HomeTab.forYou,
              icon: Icon(Icons.explore_outlined),
              label: Text('Sana özel'),
            ),
            ButtonSegment(
              value: HomeTab.mostPlayed,
              icon: Icon(Icons.repeat),
              label: Text('En çok dinlediklerin'),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (selection) =>
              setState(() => _tab = selection.first),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!_feed.hasHistory && _videos.isEmpty && !_loading) {
      return _EmptyFeed(onSearch: _openSearch);
    }

    if (_tab == HomeTab.mostPlayed) {
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
