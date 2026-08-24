import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
import '../../core/playback/playback_coordinator.dart';

/// MP3 indirme: kalite seçilir ve indirme başlar.
///
/// Not: YouTube sesi M4A/Opus olarak verir; gerçek MP3 üretmek için ses
/// çözülüp LAME ile yeniden kodlanır (bkz. native `Mp3Downloader`). Bu yüzden
/// indirme, dosyayı olduğu gibi kaydetmekten uzun sürer.
Future<void> showDownloadMenu(BuildContext context) async {
  final coordinator = PlaybackCoordinator.instance;
  final details = coordinator.details;
  if (details == null) return;

  final messenger = ScaffoldMessenger.of(context);

  if (details.isLive) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Canlı yayınlar indirilemez.')),
    );
    return;
  }

  final store = DownloadsStore.instance;
  if (store.hasDownload(details.videoId)) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Bu şarkı zaten indirilmiş.')),
    );
    return;
  }

  final bitrate = await showModalBottomSheet<int>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('MP3 indir'),
            subtitle: Text('Yüksek kalite daha büyük dosya demektir.'),
          ),
          for (final option in DownloadsStore.bitrateOptions)
            ListTile(
              leading: const Icon(Icons.audiotrack),
              title: Text('$option kbps'),
              subtitle: option == 320
                  ? const Text('En yüksek kalite')
                  : (option == 128 ? const Text('En küçük dosya') : null),
              onTap: () => Navigator.of(context).pop(option),
            ),
        ],
      ),
    ),
  );

  if (bitrate == null) return;

  messenger.showSnackBar(
    const SnackBar(content: Text('MP3 hazırlanıyor…')),
  );

  try {
    final item = await store.download(
      details.videoId,
      bitrate: bitrate,
      title: details.title,
    );
    messenger.showSnackBar(
      SnackBar(content: Text('İndirildi • ${item.sizeLabel}')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('İndirilemedi: $e')));
  }
}
