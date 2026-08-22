import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../player/mini_player.dart';
import '../player/player_screen.dart';
import 'video_list.dart';

/// Arama ekranı.
///
/// Oynatma ekranından da açılabildiği için ayrı bir ekran: kullanıcı müzik
/// dinlerken yeni bir şey aramak için geri gitmek zorunda kalmaz.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _client = ExtractionClient();
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  final _focusNode = FocusNode();

  List<VideoSummary> _results = const [];
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
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
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
      _results = const [];
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(videoId: _results[index].videoId!),
      ),
    );
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
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(_controller.text),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _results.isEmpty && !_searched && !_loading
                ? _SearchHistorySuggestions(onPick: (q) {
                    _controller.text = q;
                    _search(q);
                  })
                : VideoList(
              videos: _results,
              loading: _loading,
              hasMore: _hasMore,
              error: _error,
              emptyMessage:
                  _searched ? 'Sonuç bulunamadı.' : 'Aramak için yazmaya başla.',
              onRetry: () => _search(_controller.text),
              onLoadMore: _loadMore,
              onTap: _open,
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

/// Arama kutusu boşken son aramaları önerir.
class _SearchHistorySuggestions extends StatelessWidget {
  const _SearchHistorySuggestions({required this.onPick});

  final void Function(String query) onPick;

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final searches = store.searches;
        if (searches.isEmpty) {
          return const Center(child: Text('Aramak için yazmaya başla.'));
        }
        return ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Son aramalar'),
            ),
            for (final query in searches)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(query),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => store.removeSearch(query),
                ),
                onTap: () => onPick(query),
              ),
          ],
        );
      },
    );
  }
}
