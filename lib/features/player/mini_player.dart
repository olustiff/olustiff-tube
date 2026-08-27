import 'package:flutter/material.dart';

import '../../core/playback/playback_coordinator.dart';
import '../../core/cast/cast_controller.dart';
import '../../core/playback/playback_client.dart';
import 'player_route.dart';

/// Liste ekranlarının altında duran, çalan içeriğe dönüş çubuğu.
///
/// NewPipe'ta arka planda dinlerken çalan şeye dönmek zahmetlidir; burada tek
/// dokunuşla oynatma ekranına dönülür ve dönüldüğünde medya YENİDEN
/// BAŞLATILMAZ — kullanıcının seçtiği mod (ör. sesli) aynen korunur.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  static final PlaybackClient _playback = PlaybackClient.shared;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: PlaybackCoordinator.instance,
      builder: (context, _) {
        final nowPlaying = PlaybackCoordinator.instance;
        final details = nowPlaying.details;
        if (details == null) return const SizedBox.shrink();

        final theme = Theme.of(context);

        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: InkWell(
            onTap: () => openPlayer(context, details.videoId),
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: details.thumbnailUrl == null
                        ? const Icon(Icons.music_note)
                        : Image.network(details.thumbnailUrl!,
                            fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          details.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        Row(
                          children: [
                            Icon(
                              nowPlaying.audioOnly
                                  ? Icons.headphones
                                  : Icons.videocam_outlined,
                              size: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                details.uploaderName ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<PlaybackState>(
                    stream: _playback.stateStream,
                    builder: (context, snapshot) {
                      final cast = CastController.instance;
                      // Yayın açıkken telefonun oynatıcısı duraklatılmış
                      // durumda; düğme onun değil TELEVİZYONUN durumunu
                      // göstermeli ve onu yönetmeli. Aksi hâlde bu düğme
                      // telefonda ikinci bir ses başlatıyordu.
                      final playing = cast.isCasting
                          ? (cast.remoteState?.isPlaying ?? false)
                          : (snapshot.data?.playWhenReady ?? false);
                      final coordinator = PlaybackCoordinator.instance;
                      return IconButton(
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        onPressed: () =>
                            playing ? coordinator.pause() : coordinator.resume(),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      // Yayın açıkken kapatmak televizyonu da susturmalı;
                      // yoksa kullanıcı durduramadığı bir oynatmayla kalıyor.
                      if (CastController.instance.isCasting) {
                        await CastController.instance.stopRemote();
                      }
                      await PlaybackCoordinator.instance.stop();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

