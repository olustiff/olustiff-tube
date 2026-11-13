import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/i18n/lang.dart';

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
      SnackBar(content: Text(tr('Canlı yayınlar indirilemez.', "Live streams can't be downloaded."))),
    );
    return;
  }

  final store = DownloadsStore.instance;
  if (store.hasDownload(details.videoId)) {
    messenger.showSnackBar(
      SnackBar(content: Text(tr('Bu şarkı zaten indirilmiş.', 'This song is already downloaded.'))),
    );
    return;
  }

  final bitrate = await showModalBottomSheet<int>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(tr('MP3 indir', 'Download MP3')),
            subtitle: Text(tr('Yüksek kalite daha büyük dosya demektir.', 'Higher quality means a larger file.')),
          ),
          for (final option in DownloadsStore.bitrateOptions)
            ListTile(
              leading: const Icon(Icons.audiotrack),
              title: Text('$option kbps'),
              subtitle: option == 320
                  ? Text(tr('En yüksek kalite', 'Highest quality'))
                  : (option == 128 ? Text(tr('En küçük dosya', 'Smallest file')) : null),
              onTap: () => Navigator.of(context).pop(option),
            ),
        ],
      ),
    ),
  );

  if (bitrate == null) return;

  messenger.showSnackBar(
    SnackBar(content: Text(tr('MP3 hazırlanıyor…', 'Preparing MP3…'))),
  );

  try {
    final item = await store.download(
      details.videoId,
      bitrate: bitrate,
      title: details.title,
    );
    messenger.showSnackBar(
      SnackBar(content: Text(tr('İndirildi • ${item.sizeLabel}', 'Downloaded • ${item.sizeLabel}'))),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(tr('İndirilemedi: $e', 'Download failed: $e'))));
  }
}
