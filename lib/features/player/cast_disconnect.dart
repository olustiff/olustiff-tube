import 'package:flutter/material.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/i18n/lang.dart';

/// Yayını bitirirken ne olacağını kullanıcıya sorar.
///
/// Tek bir davranış dayatmıyoruz çünkü "bağlantıyı kes" üç ayrı isteği
/// karşılıyor ve hangisi olduğunu yalnızca kullanıcı biliyor:
/// - televizyondan sıkıldı, telefonda devam edecek,
/// - telefonu alıp gidecek ama televizyon çalmaya devam etsin,
/// - her şey sussun.
///
/// Eskiden yalnızca ilk iki seçenek vardı ve "bağlantıyı kes" sessizce
/// televizyonu çalar hâlde bırakıyordu; kullanıcı durduramadığı bir
/// oynatmayla kalıyordu.
Future<void> showCastDisconnectOptions(BuildContext context) async {
  final cast = CastController.instance;
  final device = cast.device;
  if (device == null) return;

  final choice = await showModalBottomSheet<_CastEnd>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(tr('Yayını bitir', 'Stop casting')),
            subtitle: Text(device.name),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: Text(tr('Telefonda devam et', 'Continue on phone')),
            subtitle: Text(tr("TV'de durur, telefonda kaldığı yerden çalar", 'Stops on the TV, resumes on the phone')),
            onTap: () => Navigator.of(sheetContext).pop(_CastEnd.continueOnPhone),
          ),
          ListTile(
            leading: const Icon(Icons.tv),
            title: Text(tr("TV'de çalmaya devam etsin", 'Keep playing on TV')),
            subtitle: Text(tr('Telefon yalnızca bağlantıyı bırakır', 'The phone just disconnects')),
            onTap: () => Navigator.of(sheetContext).pop(_CastEnd.keepOnTv),
          ),
          ListTile(
            leading: const Icon(Icons.stop_circle_outlined),
            title: Text(tr('Her ikisini de durdur', 'Stop both')),
            subtitle: Text(tr('TV de telefon da susar', 'Both the TV and phone stop')),
            onTap: () => Navigator.of(sheetContext).pop(_CastEnd.stopEverything),
          ),
        ],
      ),
    ),
  );

  if (choice == null || !context.mounted) return;
  await _apply(context, choice);
}

enum _CastEnd { continueOnPhone, keepOnTv, stopEverything }

Future<void> _apply(BuildContext context, _CastEnd choice) async {
  final cast = CastController.instance;
  final coordinator = PlaybackCoordinator.instance;
  // Televizyondaki konum, telefonda oradan devam edebilmek için önceden
  // alınıyor: yayın kapandıktan sonra bu bilgi kayboluyor.
  final position = cast.remoteState?.position ?? Duration.zero;
  final videoId = cast.remoteState?.videoId ?? coordinator.details?.videoId;
  final navigator = Navigator.of(context);

  switch (choice) {
    case _CastEnd.continueOnPhone:
      await cast.stopRemote();
      if (videoId == null) return;
      // Video telefonda YENİDEN açılıyor: yayın açıkken seçilen videolar
      // telefonun oynatıcısına hiç uğramıyor, orada bambaşka (ya da hiç) bir
      // medya duruyor.
      await coordinator.play(
        videoId,
        exactQueue: coordinator.queue.isEmpty ? null : coordinator.queue,
        index: coordinator.queueIndex,
      );
      await PlaybackClient.shared.seekTo(position);

    case _CastEnd.keepOnTv:
      await cast.disconnect();
      // Telefonda duraklatılmış eski medya kalmasın: kullanıcı televizyonu
      // çalar bırakıp telefonu yanına alıyor.
      await coordinator.stop();
      if (navigator.canPop()) navigator.pop();

    case _CastEnd.stopEverything:
      await cast.stopRemote();
      await coordinator.stop();
      if (navigator.canPop()) navigator.pop();
  }
}
