import 'package:flutter/material.dart';

import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../player/mini_player.dart';
import '../player/player_route.dart';
import 'video_list.dart';

/// Bir YouTube çalma listesinin içeriği.
///
/// Arama sonucundaki liste yalnızca künye taşıyor ([PlaylistSummary]); içerik
/// ancak kullanıcı dokununca çekiliyor. Yüzlerce sonucun her birinin içeriğini
/// önceden almak hem yavaş hem gereksiz olurdu.
///
/// Buradan çalınan videolar kuyruğa **liste sırasıyla** giriyor: kullanıcı bir
/// çalma listesi açtıysa sıralamayı o liste belirlemiş demektir, benzerliğe
/// göre yeniden dizmek onun seçimini bozardı.
///
/// Uzun listeler sayfa sayfa geliyor (YouTube ilk istekte ~100 video veriyor);
/// kullanıcı listenin sonuna yaklaştıkça devamı çekiliyor.
class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key, required this.playlist});

  final PlaylistSummary playlist;

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final _client = ExtractionClient();

  List<VideoSummary> _videos = const [];
  bool _loading = true;
  bool _hasMore = false;
  Object? _error;
  String? _uploaderName;

  /// Listenin BİLDİRDİĞİ toplam video sayısı.
  ///
  /// Yüklenen sayıdan farklı olabilir: YouTube ilk sayfada ~100 video veriyor,
  /// gerisi kaydırdıkça geliyor. Başlıkta yüklenen sayıyı göstermek listeyi
  /// olduğundan küçük gösteriyordu.
  int? _streamCount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await _client.playlist(widget.playlist.url);
      if (!mounted) return;
      setState(() {
        _videos = details.page.items;
        _hasMore = details.page.hasMore;
        _streamCount = details.streamCount > 0
            ? details.streamCount
            : widget.playlist.streamCount;
        _uploaderName = details.uploaderName ?? widget.playlist.uploaderName;
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

  /// Listenin sonraki sayfası.
  ///
  /// Hata durumunda eldeki videolar korunuyor ve devamı kapatılıyor: yarım bir
  /// listeyi göstermek, kullanıcıyı boş ekrana düşürmekten iyi.
  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await _client.loadMore(ExtractionClient.kindPlaylist);
      if (!mounted) return;
      setState(() {
        _videos = [..._videos, ...page.items];
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasMore = false;
        _loading = false;
      });
    }
  }

  void _open(int index) {
    final videoId = _videos[index].videoId;
    if (videoId == null) return;
    PlaybackCoordinator.instance.play(
      videoId,
      // Listenin tamamı ve seçilen konum veriliyor: kuyruk liste sırasını
      // koruyor ve sıradaki gerçekten "listedeki sonraki" oluyor.
      exactQueue: _videos,
      index: index,
    );
    openPlayer(context, videoId);
  }

  @override
  Widget build(BuildContext context) {
    final total = _streamCount ?? widget.playlist.streamCount;
    final subtitle = [
      ?_uploaderName,
      if (total != null) '$total video',
    ].join(' • ');

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: VideoList(
              videos: _videos,
              loading: _loading,
              hasMore: _hasMore,
              error: _error,
              emptyMessage: 'Bu listede video yok.',
              onRetry: _load,
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

/// Arama sonuçlarındaki çalma listesi satırı.
///
/// [VideoTile]'dan ayrı bir görünüm: kapağın üstündeki liste rozeti olmadan
/// kullanıcı satırın bir video mu liste mi olduğunu ancak dokunduktan sonra
/// anlıyordu.
class PlaylistTile extends StatelessWidget {
  const PlaylistTile({super.key, required this.playlist, required this.onTap});

  final PlaylistSummary playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = playlist.streamCount;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      leading: SizedBox(
        width: 110,
        height: 62,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (playlist.thumbnailUrl != null)
                Image.network(
                  playlist.thumbnailUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.playlist_play),
                  ),
                )
              else
                const ColoredBox(
                  color: Colors.black26,
                  child: Icon(Icons.playlist_play),
                ),
              // Sağ kenardaki koyu şerit: kapağa bakan biri bunun tek bir
              // video değil bir liste olduğunu buradan anlıyor.
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: 42,
                  color: Colors.black.withValues(alpha: 0.6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.playlist_play,
                          size: 18, color: Colors.white),
                      if (count != null)
                        Text(
                          '$count',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      title: Text(
        playlist.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Text(
        [
          ?playlist.uploaderName,
          if (count != null) '$count video' else 'Çalma listesi',
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: onTap,
    );
  }
}
