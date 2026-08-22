import 'package:flutter/material.dart';

import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../player/mini_player.dart';
import '../player/player_screen.dart';

/// Faz 1 kanıt ekranı: trend videoları listeler ve arama yapılmasına izin
/// verir. Gerçek "TV/telefon adaptive" tasarım Faz 4'te gelecek — burada amaç
/// extraction pipeline'ının uçtan uca çalıştığını göstermek.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _client = ExtractionClient();
  final _searchController = TextEditingController();

  Future<List<VideoSummary>>? _future;
  String _title = 'Trendler';

  @override
  void initState() {
    super.initState();
    _loadTrending();
  }

  void _loadTrending() {
    setState(() {
      _title = 'Trendler';
      _future = _client.trending();
    });
  }

  void _search(String query) {
    if (query.trim().isEmpty) return;
    setState(() {
      _title = '"$query" için sonuçlar';
      _future = _client.search(query.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Video ara...',
            border: InputBorder.none,
          ),
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.trending_up),
            tooltip: 'Trendlere dön',
            onPressed: _loadTrending,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(_title, style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(
            child: FutureBuilder<List<VideoSummary>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _ErrorView(
                    error: snapshot.error,
                    onRetry: _loadTrending,
                  );
                }
                final items = snapshot.data ?? const [];
                if (items.isEmpty) {
                  return const Center(child: Text('Sonuç bulunamadı.'));
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) => _VideoTile(video: items[index]),
                );
              },
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.video});

  final VideoSummary video;

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final d = Duration(seconds: seconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: SizedBox(
        width: 100,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: video.thumbnailUrl == null
              ? Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)
              : Image.network(video.thumbnailUrl!, fit: BoxFit.cover),
        ),
      ),
      title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (video.uploaderName != null) video.uploaderName,
          _formatDuration(video.durationSeconds),
        ].where((e) => e != null && e.isNotEmpty).join(' • '),
      ),
      onTap: video.videoId == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PlayerScreen(videoId: video.videoId!),
                ),
              ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
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
            FilledButton(onPressed: onRetry, child: const Text('Tekrar dene')),
          ],
        ),
      ),
    );
  }
}
