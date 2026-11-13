import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/models.dart';
import '../../core/i18n/lang.dart';
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

/// Ana ekran: "Sana özel" (en çok dinlediklerin) ve "Favoriler" (kalplediklerin).
///
/// Trend listesi bilerek gösterilmiyor — kullanıcı kendi ilgi alanlarını
/// görmek istiyor.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _library = LibraryStore.instance;

  /// Televizyonda kumandanın yukarı oku bu düğmeye çıkıyor.
  final _searchFocus = FocusNode(debugLabel: 'anaEkranArama');

  HomeTab _tab = HomeTab.forYou;

  @override
  void initState() {
    super.initState();
    // Güncelleme denetimi açılışı geciktirmesin: ilk kare çizildikten sonra
    // arka planda sorulur, yalnızca yeni sürüm varsa pencere gelir.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdatePrompt.maybeShow(context);
    });
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _hasHistory =>
      _library.watched.isNotEmpty || _library.favorites.isNotEmpty;

  List<VideoSummary> get _currentList =>
      _tab == HomeTab.forYou ? _library.mostPlayed : _library.favorites;

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
            tooltip: tr('Ara', 'Search'),
            onPressed: _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.library_music_outlined),
            tooltip: tr('Kitaplık', 'Library'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LibraryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: tr('Ayarlar', 'Settings'),
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
    if (!_hasHistory) {
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
    if (!_hasHistory) return _EmptyFeed(onSearch: _openSearch);

    if (_tab == HomeTab.favorites) {
      return VideoList(
        videos: _library.favorites,
        loading: false,
        hasMore: false,
        onLoadMore: () {},
        onTap: _open,
        emptyMessage: tr(
          'Henüz favorin yok.\n'
              'Çalan şarkıda ♥ simgesine dokunduğunda burada görünür.',
          'No favorites yet.\n'
              'Tap ♥ on the playing song and it will show up here.',
        ),
      );
    }

    // Cihazdaki dinleme sayaçlarından: internet gerekmiyor, açılışta anında
    // dolu. (Bir ara burada YouTube'un "benzer videolar"ından öneri akışı
    // vardı; kullanıcı en çok dinlediklerini görmek istedi.)
    return VideoList(
      videos: _library.mostPlayed,
      loading: false,
      hasMore: false,
      onLoadMore: () {},
      onTap: _open,
      emptyMessage: tr(
        'Henüz tekrar dinlediğin bir şey yok.\n'
            'Bir şarkıyı ikinci kez açtığında burada görünür.',
        "You haven't replayed anything yet.\n"
            'Play a song a second time and it will show up here.',
      ),
    );
  }
}

/// Geçmiş henüz boşken gösterilir: buranın neyle dolacağını anlatır.
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
              tr('Dinledikçe burası dolacak',
                  'This fills up as you listen'),
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              tr('En çok dinlediklerin ve kalplediklerin burada görünür.',
                  'Your most played and hearted songs show up here.'),
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onSearch,
              icon: const Icon(Icons.search),
              label: Text(tr('Aramaya başla', 'Start searching')),
            ),
          ],
        ),
      ),
    );
  }
}

