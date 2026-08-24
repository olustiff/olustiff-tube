import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
import '../../core/data/library_store.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';

/// Süren MP3 indirmelerini gösteren ince şerit.
///
/// MP3 üretimi ses yeniden kodlandığı için şarkı başına 30-60 sn sürüyor;
/// kullanıcı bu sırada başka ekranlarda gezindiği için "indirme başladı mı"
/// sorusunun cevabı ekranda kalıcı olarak durmalı. Bu yüzden şerit
/// [MiniPlayer]'ın hemen üstünde, liste ekranlarının altında yaşıyor.
class DownloadProgressBar extends StatelessWidget {
  const DownloadProgressBar({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = DownloadsStore.instance;
    final library = LibraryStore.instance;
    final playback = PlaybackCoordinator.instance;

    // İlerleme DownloadsStore'dan, indirilen şarkının adı ise geçmiş/kuyruk
    // gibi başlığı bilen kaynaklardan geliyor; ikisini de dinlemek gerekiyor.
    return AnimatedBuilder(
      animation: Listenable.merge([downloads, library, playback]),
      builder: (context, _) {
        final active = _activeDownloads(downloads, library, playback);
        // Süren indirme yokken şerit hiç yer kaplamamalı.
        if (active.isEmpty) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final progress =
            active.map((d) => d.progress).reduce((a, b) => a + b) /
                active.length;

        // Tek çubuk birden fazla indirmeyi temsil edemez; o yüzden çok
        // indirme varken adet, tekken şarkı adı yazılıyor.
        final label = active.length > 1
            ? '${active.length} indirme sürüyor'
            : (active.first.title ?? 'MP3 hazırlanıyor…');

        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.downloading,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '%${(progress * 100).round()}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    // Native taraf ilk ilerlemeyi bildirene kadar sabit sıfır
                    // duran çubuk "takıldı" izlenimi veriyor; o aralıkta
                    // belirsiz (akan) çubuk gösteriliyor.
                    value: progress > 0 ? progress : null,
                    minHeight: 3,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Süren indirmeleri, bilinebiliyorsa adlarıyla birlikte toplar.
  ///
  /// [DownloadsStore] yalnızca "şu videoId iniyor mu" sorusuna cevap veriyor;
  /// süren indirmelerin listesini vermiyor. İndirme her zaman oynatma
  /// ekranından başlatıldığı için aday videoId'leri çalan içerik, kuyruk ve
  /// izleme geçmişinden çıkarıyoruz — başlık da aynı kayıtlardan geliyor,
  /// böylece uydurma ad göstermiyoruz.
  List<_ActiveDownload> _activeDownloads(
    DownloadsStore downloads,
    LibraryStore library,
    PlaybackCoordinator playback,
  ) {
    final candidates = <String, String?>{};

    void add(String? videoId, String? title) {
      if (videoId == null || videoId.isEmpty) return;
      // İlk kaynak (çalan içerik) en güvenilir başlığı taşıyor; sonrakiler
      // yalnızca eksik başlığı tamamlar.
      final existing = candidates[videoId];
      if (candidates.containsKey(videoId) && existing != null) return;
      candidates[videoId] = (title != null && title.isNotEmpty) ? title : null;
    }

    add(playback.details?.videoId, playback.details?.title);
    add(playback.pending?.videoId, playback.pending?.title);
    for (final VideoSummary video in playback.queue) {
      add(video.videoId, video.title);
    }
    for (final VideoSummary video in library.watched) {
      add(video.videoId, video.title);
    }

    return [
      for (final entry in candidates.entries)
        if (downloads.isDownloading(entry.key))
          _ActiveDownload(
            title: entry.value,
            progress: downloads.progressOf(entry.key),
          ),
    ];
  }
}

/// Süren tek bir indirme: adı bilinmiyorsa [title] boş kalır.
class _ActiveDownload {
  const _ActiveDownload({required this.title, required this.progress});

  final String? title;
  final double progress;
}
