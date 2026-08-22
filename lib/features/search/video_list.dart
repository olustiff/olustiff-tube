import 'package:flutter/material.dart';

import '../../core/extraction/models.dart';

/// Sonsuz kaydırmalı video listesi.
///
/// YouTube tek istekte ~20 sonuç verdiği için liste sonuna yaklaşıldığında
/// [onLoadMore] tetiklenir; böylece arama sonuçları "kısa" kalmaz.
class VideoList extends StatefulWidget {
  const VideoList({
    super.key,
    required this.videos,
    required this.loading,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
    this.error,
    this.onRetry,
    this.emptyMessage = 'Sonuç bulunamadı.',
  });

  final List<VideoSummary> videos;
  final bool loading;
  final bool hasMore;
  final Object? error;
  final VoidCallback? onRetry;
  final String emptyMessage;
  final VoidCallback onLoadMore;
  final void Function(int index) onTap;

  @override
  State<VideoList> createState() => _VideoListState();
}

class _VideoListState extends State<VideoList> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Kullanıcı listenin sonuna varmadan yüklemeye başla ki kaydırma akıcı
    // kalsın ve bekleme hissedilmesin.
    if (position.pixels >= position.maxScrollExtent - 600) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.error != null && widget.videos.isEmpty) {
      return _ErrorView(error: widget.error, onRetry: widget.onRetry);
    }
    if (widget.videos.isEmpty) {
      return Center(
        child: widget.loading
            ? const CircularProgressIndicator()
            : Text(widget.emptyMessage),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      // Son satır, daha fazlası varken yükleme göstergesi olur.
      itemCount: widget.videos.length + (widget.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= widget.videos.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return VideoTile(
          video: widget.videos[index],
          onTap: widget.videos[index].videoId == null
              ? null
              : () => widget.onTap(index),
        );
      },
    );
  }
}

class VideoTile extends StatelessWidget {
  const VideoTile({super.key, required this.video, this.onTap});

  final VideoSummary video;
  final VoidCallback? onTap;

  static String formatDuration(int seconds) {
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
              ? Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest)
              : Image.network(video.thumbnailUrl!, fit: BoxFit.cover),
        ),
      ),
      title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (video.uploaderName != null) video.uploaderName!,
          formatDuration(video.durationSeconds),
        ].where((e) => e.isNotEmpty).join(' • '),
      ),
      onTap: onTap,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

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
            if (onRetry != null)
              FilledButton(onPressed: onRetry, child: const Text('Tekrar dene')),
          ],
        ),
      ),
    );
  }
}
