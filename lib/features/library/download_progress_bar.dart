import 'package:flutter/material.dart';

import '../../core/data/downloads_store.dart';
import '../../core/i18n/lang.dart';

/// Süren MP3 indirmelerini ekranın altında gösteren ince şerit.
///
/// İndirme uzun sürüyor (ses çözülüp yeniden kodlanıyor); geri bildirim
/// olmayınca "başladı mı?" belirsiz kalıyordu. Süren indirme yoksa hiç yer
/// kaplamaz.
class DownloadProgressBar extends StatelessWidget {
  const DownloadProgressBar({super.key});

  @override
  Widget build(BuildContext context) {
    final store = DownloadsStore.instance;

    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final active = store.activeDownloads;
        if (active.isEmpty) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final average =
            active.map((e) => e.progress).reduce((a, b) => a + b) /
                active.length;

        final label = active.length > 1
            ? tr('${active.length} indirme sürüyor',
                '${active.length} downloads in progress')
            : (active.first.title.isEmpty
                ? tr('MP3 hazırlanıyor…', 'Preparing MP3…')
                : active.first.title);

        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.download, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      tr('%${(average * 100).round()}',
                          '${(average * 100).round()}%'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  // İlerleme henüz gelmediyse akan çubuk göster: sabit sıfır
                  // "takıldı" izlenimi veriyordu.
                  child: LinearProgressIndicator(
                    value: average > 0 ? average : null,
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
}
