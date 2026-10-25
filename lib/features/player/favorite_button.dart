import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/playback/playback_coordinator.dart';

/// Çalan şarkıyı/videoyu favorilere ekleyen kalp.
///
/// Ana sayfadaki "Favoriler" sekmesi yalnızca burada işaretlenenleri
/// gösteriyor.
class FavoriteButton extends StatelessWidget {
  const FavoriteButton({super.key, required this.coordinator});

  final PlaybackCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final summary = coordinator.currentSummary;
        final isFavorite = store.isFavorite(summary?.videoId);
        return IconButton(
          tooltip: isFavorite ? 'Favorilerden çıkar' : 'Favorilere ekle',
          icon: Icon(
            isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? Theme.of(context).colorScheme.primary : null,
          ),
          onPressed: summary == null
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final added = await store.toggleFavorite(summary);
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(
                          added
                              ? 'Favorilere eklendi'
                              : 'Favorilerden çıkarıldı',
                        ),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                },
        );
      },
    );
  }
}
