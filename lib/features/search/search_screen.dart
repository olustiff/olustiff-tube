import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/playback/ui_channel.dart';
import '../../core/ui/tv_mode.dart';
import '../library/download_progress_bar.dart';
import '../player/mini_player.dart';
import '../player/player_route.dart';
import 'search_suggestions.dart';
import 'tv_search_screen.dart';
import 'video_list.dart';

/// Arama ekranı.
///
/// Oynatma ekranından da açılabildiği için ayrı bir ekran: kullanıcı müzik
/// dinlerken yeni bir şey aramak için geri gitmek zorunda kalmaz.
///
/// Cihaza göre iki ayrı ekran var. Televizyonda sistem klavyesi kumandayla
/// kullanılamıyordu (bkz. [TvSearchScreen]); telefonda ise dokunmatik klavye
/// zaten doğru araç.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  Widget build(BuildContext context) {
    // Cihaz türü açılışta bir kez belirleniyor ve çalışma sırasında
    // değişmiyor (bkz. [TvMode]); dinlemeye gerek yok.
    return TvMode.isTv.value
        ? TvSearchScreen(initialQuery: initialQuery)
        : PhoneSearchScreen(initialQuery: initialQuery);
  }
}

/// Dokunmatik arama ekranı: sistem klavyesi, yazdıkça öneriler, mikrofon.
class PhoneSearchScreen extends StatefulWidget {
  const PhoneSearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  State<PhoneSearchScreen> createState() => _PhoneSearchScreenState();
}

class _PhoneSearchScreenState extends State<PhoneSearchScreen> {
  final _client = ExtractionClient();
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  final _focusNode = FocusNode();

  late final SuggestionLoader _loader = SuggestionLoader(
    fetch: (query) => _client.suggestions(query),
  );

  /// YouTube'un otomatik tamamlamaları; geçmişle birlikte gösteriliyor.
  List<String> _remote = const [];

  /// Cihazda ses tanıma varsa mikrofon düğmesi çizilir.
  bool _voiceAvailable = false;
  bool _voiceRunning = false;

  List<VideoSummary> _results = const [];
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;
  bool _searched = false;

  /// Sonuçların hangi metin için alındığı.
  ///
  /// Kullanıcı aramadan sonra yazmaya devam ederse eldeki sonuçlar artık o
  /// metne ait değil; o an yeniden önerilere dönülüyor.
  String? _searchedQuery;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    _checkVoice();
    final initial = widget.initialQuery;
    if (initial != null && initial.trim().isNotEmpty) {
      _search(initial);
    } else {
      // Arama için açıldıysa klavye hemen gelsin.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusNode.requestFocus());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focusNode.dispose();
    _loader.dispose();
    super.dispose();
  }

  Future<void> _checkVoice() async {
    final available = await UiChannel.instance.isVoiceSearchAvailable();
    if (!mounted) return;
    setState(() => _voiceAvailable = available);
  }

  /// Öneri listesi mi, sonuç listesi mi gösterilecek.
  bool get _showSuggestions =>
      _searchedQuery == null || _controller.text.trim() != _searchedQuery;

  void _onQueryChanged() {
    _loader.request(_controller.text, (remote) {
      if (!mounted) return;
      setState(() => _remote = remote);
    });
    // Metin değişince öneri/sonuç seçimi de değişebilir.
    setState(() {});
  }

  Future<void> _startVoice() async {
    if (_voiceRunning) return;
    setState(() => _voiceRunning = true);
    final spoken = await UiChannel.instance.startVoiceSearch();
    if (!mounted) return;
    setState(() => _voiceRunning = false);
    // Kullanıcı vazgeçtiyse null döner; yazdığı metin silinmemeli.
    if (spoken == null || spoken.trim().isEmpty) return;
    _controller.text = spoken.trim();
    await _search(spoken);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
      _results = const [];
      _searchedQuery = query.trim();
    });
    try {
      final trimmed = query.trim();
      await LibraryStore.instance.recordSearch(trimmed);
      final page = await _client.search(trimmed);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _hasMore = page.hasMore;
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

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await _client.loadMore(ExtractionClient.kindSearch);
      if (!mounted) return;
      setState(() {
        _results = [..._results, ...page.items];
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Devamı gelmezse eldeki sonuçlar korunur; kullanıcıya boş ekran
      // gösterip mevcut listeyi kaybetmiyoruz.
      setState(() {
        _hasMore = false;
        _loading = false;
      });
    }
  }

  void _open(int index) {
    PlaybackCoordinator.instance
        .play(_results[index].videoId!, context: _results);
    openPlayer(context, _results[index].videoId!);
  }

  void _pick(String query) {
    _controller.text = query;
    _search(query);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Video ara...',
            border: InputBorder.none,
          ),
          onSubmitted: _search,
        ),
        actions: [
          // Ses tanıma olmayan cihazda düğme HİÇ çizilmez: basınca bir şey
          // olmayan düğme, olmayan düğmeden kötü.
          if (_voiceAvailable)
            IconButton(
              icon: Icon(_voiceRunning ? Icons.mic : Icons.mic_none),
              tooltip: 'Sesle ara',
              onPressed: _voiceRunning ? null : _startVoice,
            ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(_controller.text),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _showSuggestions
                ? _SuggestionList(
                    query: _controller.text,
                    remote: _remote,
                    onPick: _pick,
                  )
                : VideoList(
                    videos: _results,
                    loading: _loading,
                    hasMore: _hasMore,
                    error: _error,
                    emptyMessage: _searched
                        ? 'Sonuç bulunamadı.'
                        : 'Aramak için yazmaya başla.',
                    onRetry: () => _search(_controller.text),
                    onLoadMore: _loadMore,
                    onTap: _open,
                  ),
          ),
          const DownloadProgressBar(),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

/// Arama kutusunun altındaki öneriler: önce kullanıcının geçmişi, sonra
/// YouTube'un otomatik tamamlamaları.
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.query,
    required this.remote,
    required this.onPick,
  });

  final String query;
  final List<String> remote;
  final void Function(String query) onPick;

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final history = store.searches;
        final suggestions = SearchSuggestions.merge(
          query: query,
          history: history,
          remote: remote,
        );
        if (suggestions.isEmpty) {
          return const Center(child: Text('Aramak için yazmaya başla.'));
        }
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                query.trim().isEmpty ? 'Son aramalar' : 'Öneriler',
              ),
            ),
            for (final suggestion in suggestions)
              if (SearchSuggestions.isFromHistory(suggestion, history))
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(suggestion),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => store.removeSearch(suggestion),
                  ),
                  onTap: () => onPick(suggestion),
                )
              else
                ListTile(
                  leading: const Icon(Icons.search),
                  title: Text(suggestion),
                  onTap: () => onPick(suggestion),
                ),
          ],
        );
      },
    );
  }
}
