import 'package:flutter/material.dart';

import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../player/mini_player.dart';
import '../player/player_route.dart';
import 'video_list.dart';

/// Bir YouTube kanalının videoları.
///
/// Çalma listesi ekranından bir noktada AYRILIYOR: oradan çalınan videolar
/// kuyruğa liste sırasıyla giriyor, çünkü sırayı listeyi yapan kişi belirlemiş.
/// Kanal ise düzenlenmiş bir sıra değil, yeniden eskiye bir akış; buradan
/// çalınan video normal kuyruk kuralıyla devam ediyor (benzerlik + kanal
/// çeşitliliği). Kanalın 400 videosunu sırayla çalmak kimsenin istediği şey
/// değil.
class ChannelScreen extends StatefulWidget {
  const ChannelScreen({super.key, required this.channel});

  final ChannelSummary channel;

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  final _client = ExtractionClient();

  List<VideoSummary> _videos = const [];
  bool _loading = true;
  bool _hasMore = false;
  Object? _error;
  int? _subscriberCount;

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
      final details = await _client.channel(widget.channel.url);
      if (!mounted) return;
      setState(() {
        _videos = details.page.items;
        _hasMore = details.page.hasMore;
        _subscriberCount =
            details.subscriberCount ?? widget.channel.subscriberCount;
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
      final page = await _client.loadMore(ExtractionClient.kindChannel);
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
    PlaybackCoordinator.instance.play(videoId, context: _videos);
    openPlayer(context, videoId);
  }

  @override
  Widget build(BuildContext context) {
    final count = _subscriberCount;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (count != null)
              Text(
                '${formatCompactCount(count)} abone',
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
              emptyMessage: 'Bu kanalda gösterilecek video yok.',
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

/// Büyük sayıları kısaltır: 2100000 → "2,1 Mn".
///
/// Abone sayıları ham hâliyle okunmuyor; YouTube da kısaltarak gösteriyor.
String formatCompactCount(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) {
    final thousands = value / 1000;
    // 10 binin altında ondalık anlamlı (9,4 B), üstünde gürültü (943 B).
    return thousands < 10
        ? '${thousands.toStringAsFixed(1).replaceAll('.', ',')} B'
        : '${thousands.round()} B';
  }
  final millions = value / 1000000;
  return millions < 10
      ? '${millions.toStringAsFixed(1).replaceAll('.', ',')} Mn'
      : '${millions.round()} Mn';
}

/// Arama sonuçlarındaki kanal satırı.
class ChannelTile extends StatelessWidget {
  const ChannelTile({super.key, required this.channel, required this.onTap});

  final ChannelSummary channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subscribers = channel.subscriberCount;
    final videos = channel.streamCount;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      // Yuvarlak avatar: kanalı videodan ve listeden ayıran ilk işaret.
      leading: CircleAvatar(
        radius: 28,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        foregroundImage: channel.thumbnailUrl != null
            ? NetworkImage(channel.thumbnailUrl!)
            : null,
        child: const Icon(Icons.person_outline),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          if (channel.verified) ...[
            const SizedBox(width: 4),
            Icon(Icons.check_circle, size: 15, color: theme.hintColor),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (subscribers != null) '${formatCompactCount(subscribers)} abone',
          if (videos != null) '$videos video',
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: onTap,
    );
  }
}
