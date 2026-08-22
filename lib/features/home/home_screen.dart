import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../library/library_screen.dart';
import '../player/mini_player.dart';
import '../player/player_screen.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import '../settings/settings_screen.dart';
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

  List<VideoSummary> _videos = const [];
  bool _loading = false;
  Object? _error;

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

  /// Geçmiş boşken ilk arama yapıldığında akış kendiliğinden dolsun.
  void _onLibraryChanged() {
    if (_videos.isEmpty && !_loading && _feed.hasHistory) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final videos = await _feed.load();
      if (!mounted) return;
      setState(() {
        _videos = videos;
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

  void _open(int index) {
    final videoId = _videos[index].videoId!;
    PlaybackCoordinator.instance.play(videoId, context: _videos);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(videoId: videoId)),
    );
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
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          const MiniPlayer(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (!_feed.hasHistory && _videos.isEmpty && !_loading) {
      return _EmptyFeed(onSearch: _openSearch);
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
