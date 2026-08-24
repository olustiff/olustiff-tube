import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
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
        const SnackBar(
          content: Text(
            'Klasör açılamadı. Dosyalar: Müzik / oLusTifF',
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
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Henüz indirilen yok.\n'
                'Bir videoyu açıp menüden "MP3 indir" diyebilirsin.\n\n'
                'İndirilenler telefonundaki Müzik / oLusTifF klasörüne kaydedilir.',
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
                  const SizedBox(width: 8),
                  Text('${totalMb.toStringAsFixed(0)} MB'),
                  const Spacer(),
                  // Dosyalar ortak Müzik klasöründe; kullanıcı onları
                  // telefonun dosya yöneticisinde de görebilsin.
                  TextButton.icon(
                    onPressed: () => _openFolder(context),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Klasörü aç'),
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
      title: const Text('İndirmeyi sil'),
      content: Text('"${item.title}" cihazdan silinecek.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Vazgeç'),
        ),
        TextButton(
          // Yıkıcı eylem tema hata rengiyle ayrışsın: kullanıcı hangi
          // düğmenin dosyayı sildiğini bakar bakmaz görsün.
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Sil'),
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
    messenger.showSnackBar(SnackBar(content: Text('Silinemedi: $e')));
  }
}
