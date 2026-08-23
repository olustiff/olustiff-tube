import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
import '../../core/playback/playback_client.dart';
import '../search/video_list.dart';

/// İndirilenler: internet olmadan oynatılabilen dosyalar.
class DownloadsTab extends StatelessWidget {
  const DownloadsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final store = DownloadsStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final items = store.items;
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Henüz indirilen yok.\n'
                'Bir videoyu açıp menüden "MP3 indir" diyebilirsin.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final totalMb = items.fold<int>(0, (sum, i) => sum + i.sizeBytes) /
            (1024 * 1024);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('${items.length} dosya'),
                  const Spacer(),
                  Text('${totalMb.toStringAsFixed(0)} MB'),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    leading: const Icon(Icons.audiotrack),
                    title: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (item.uploaderName != null) item.uploaderName!,
                        'MP3 ${item.bitrate}kbps',
                        item.sizeLabel,
                        VideoTile.formatDuration(item.durationSeconds),
                      ].where((e) => e.isNotEmpty).join(' • '),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => store.delete(item),
                    ),
                    onTap: () => PlaybackClient.shared.playLocal(
                      path: item.path,
                      title: item.title,
                      artist: item.uploaderName,
                      audioOnly: true,
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
