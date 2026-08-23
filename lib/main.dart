import 'package:flutter/material.dart';

import 'core/data/downloads_store.dart';
import 'core/data/library_store.dart';
import 'core/update/update_service.dart';
import 'core/data/settings_store.dart';
import 'core/playback/playback_client.dart';
import 'core/playback/playback_coordinator.dart';
import 'features/home/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Geçmiş ve tercihler arayüz çizilmeden önce hazır olsun.
  await LibraryStore.instance.load();
  await SettingsStore.instance.load();
  await DownloadsStore.instance.load();
  await UpdateService.instance.load();

  // Bluetooth bağlanınca ne çalacağını hazırla. Hiç bir şey çalınmadıysa
  // favorilerden (yoksa geçmişten) ilk parça yedek olarak ayarlanır;
  // ikisi de boşsa bir şey çalmaz — rastgele içerikle rahatsız etmeyiz.
  final settings = SettingsStore.instance;
  await PlaybackClient.shared
      .setBluetoothAutoPlay(settings.bluetoothAutoPlay);
  final library = LibraryStore.instance;
  final fallback = library.mostPlayed.firstOrNull ?? library.watched.firstOrNull;
  if (fallback?.videoId != null) {
    await PlaybackClient.shared.rememberLastPlayed(
      videoId: fallback!.videoId!,
      title: fallback.title,
      artist: fallback.uploaderName,
    );
  }

  // Native taraf kuyrukta kendi başına ilerleyebildiği için (ekran kapalıyken
  // de) arayüzü gerçekte çalanla eşitliyoruz.
  PlaybackClient.shared.stateStream.listen((state) {
    final videoId = state.currentVideoId;
    if (videoId != null) {
      PlaybackCoordinator.instance.syncFromNative(videoId, state.queueIndex);
    }
  });

  runApp(const AkisApp());
}

class AkisApp extends StatelessWidget {
  const AkisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'oLusTifF',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.redAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
