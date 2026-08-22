import 'package:flutter/material.dart';

import 'core/data/library_store.dart';
import 'core/data/settings_store.dart';
import 'core/playback/playback_client.dart';
import 'core/playback/playback_coordinator.dart';
import 'features/home/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Geçmiş ve tercihler arayüz çizilmeden önce hazır olsun.
  await LibraryStore.instance.load();
  await SettingsStore.instance.load();

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
      title: 'Akış',
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
