import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
import '../../core/i18n/lang.dart';
import '../../core/playback/playback_client.dart';
import '../search/video_list.dart';

/// İndirilenler: internet olmadan oynatılabilen dosyalar.
class DownloadsTab extends StatelessWidget {
  const DownloadsTab({super.key});

  /// Sistem dosya/müzik uygulamasında indirme klasörünü açar.
  Future<void> _openFolder(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await DownloadsStore.instance.openFolder();
    if (!opened) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Klasör açılamadı. Dosyalar: Müzik / oLusTifF',
                "Couldn't open the folder. Files: Music / oLusTifF"),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = DownloadsStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final items = store.items;
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                tr(
                  'Henüz indirilen yok.\n'
                      'Bir videoyu açıp menüden "MP3 indir" diyebilirsin.\n\n'
                      'İndirilenler telefonundaki Müzik / oLusTifF klasörüne kaydedilir.',
                  'No downloads yet.\n'
                      'Open a video and choose "Download MP3" from the menu.\n\n'
                      'Downloads are saved to the Music / oLusTifF folder on your phone.',
                ),
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
                  Text(tr('${items.length} dosya',
                      items.length == 1 ? '1 file' : '${items.length} files')),
                  const SizedBox(width: 8),
                  Text('${totalMb.toStringAsFixed(0)} MB'),
                  const Spacer(),
                  // Dosyalar ortak Müzik klasöründe; kullanıcı onları
                  // telefonun dosya yöneticisinde de görebilsin.
                  TextButton.icon(
                    onPressed: () => _openFolder(context),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(tr('Klasörü aç', 'Open folder')),
                  ),
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
                      onPressed: () => _confirmDelete(context, store, item),
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

/// Silmeden önce onay ister.
///
/// Yanlışlıkla dokunulan çöp kutusu pahalıya patlıyor: aynı şarkıyı geri
/// getirmek yeniden kodlama yüzünden 30-60 sn süren yeni bir indirme demek.
Future<void> _confirmDelete(
  BuildContext context,
  DownloadsStore store,
  DownloadedItem item,
) async {
  // Diyalog kapandıktan sonra context'in hâlâ geçerli olacağı garanti
  // olmadığı için messenger'ı şimdiden yakalıyoruz.
  final messenger = ScaffoldMessenger.of(context);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('İndirmeyi sil', 'Delete download')),
      content: Text(tr('"${item.title}" cihazdan silinecek.',
          '"${item.title}" will be deleted from this device.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('Vazgeç', 'Cancel')),
        ),
        TextButton(
          // Yıkıcı eylem tema hata rengiyle ayrışsın: kullanıcı hangi
          // düğmenin dosyayı sildiğini bakar bakmaz görsün.
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('Sil', 'Delete')),
        ),
      ],
    ),
  );

  // Diyalog dışına dokunularak kapatılırsa sonuç null gelir; yalnızca açık
  // onayda siliyoruz.
  if (confirmed != true) return;

  try {
    await store.delete(item);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Silinemedi: $e', "Couldn't delete: $e"))));
  }
}
