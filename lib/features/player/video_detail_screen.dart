import 'package:flutter/material.dart';

import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';

/// Faz 1 kanıt ekranı: seçilen videonun reklamsız stream URL'lerini çözüp
/// gösterir. Gerçek oynatıcı (ExoPlayer/Media3 entegrasyonu) Faz 2'de bu
/// ekranın yerini alacak.
class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({super.key, required this.videoId});

  final String videoId;

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  final _client = ExtractionClient();
  late final Future<VideoDetails> _future;

  @override
  void initState() {
    super.initState();
    _future = _client.videoDetails(widget.videoId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Video')),
      body: FutureBuilder<VideoDetails>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          final d = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(d.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '${d.uploaderName ?? ''} • ${d.viewCount} görüntülenme',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const Divider(height: 32),
              Text(
                'Çözülen stream\'ler (henüz oynatıcı yok — Faz 2)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              _StreamSection(title: 'Video + Ses', streams: d.videoStreams),
              _StreamSection(title: 'Sadece Video', streams: d.videoOnlyStreams),
              _AudioSection(streams: d.audioStreams),
              if (d.description.isNotEmpty) ...[
                const Divider(height: 32),
                Text('Açıklama', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(d.description),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StreamSection extends StatelessWidget {
  const _StreamSection({required this.title, required this.streams});

  final String title;
  final List<VideoStreamInfo> streams;

  @override
  Widget build(BuildContext context) {
    if (streams.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        for (final s in streams)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.video_file_outlined),
            title: Text('${s.resolution ?? '?'} • ${s.format ?? '?'} • ${s.fps} fps'),
            subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _AudioSection extends StatelessWidget {
  const _AudioSection({required this.streams});

  final List<AudioStreamInfo> streams;

  @override
  Widget build(BuildContext context) {
    if (streams.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sadece Ses', style: Theme.of(context).textTheme.labelLarge),
        for (final s in streams)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.audiotrack_outlined),
            title: Text('${s.format ?? '?'} • ${s.averageBitrate} bps'),
            subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}
