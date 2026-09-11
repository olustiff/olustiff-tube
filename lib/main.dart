import 'dart:async';

import 'package:flutter/material.dart';

import 'core/cast/cast_receiver.dart';
import 'core/data/downloads_store.dart';
import 'core/data/library_store.dart';
import 'core/ui/tv_mode.dart';
import 'core/update/update_service.dart';
import 'core/data/settings_store.dart';
import 'core/playback/playback_client.dart';
import 'core/playback/playback_coordinator.dart';
import 'features/home/home_screen.dart';
import 'features/player/player_route.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Geçmiş ve tercihler arayüz çizilmeden önce hazır olsun.
  await LibraryStore.instance.load();
  await SettingsStore.instance.load();
  await DownloadsStore.instance.load();
  await UpdateService.instance.load();
  // Televizyonda arayüz kumandaya göre uyarlanıyor.
  await TvMode.detect();

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
  //
  // Aynı akış "kaldığın yerden devam" için de kullanılıyor: konumu ayrıca
  // yakalamaya gerek yok, native zaten düzenli aralıklarla bildiriyor.
  PlaybackClient.shared.stateStream.listen((state) {
    final videoId = state.currentVideoId;
    if (videoId != null) {
      PlaybackCoordinator.instance.syncFromNative(videoId, state.queueIndex);
      PlaybackCoordinator.instance.updatePlayOrder(state.queueOrder);
      PlaybackCoordinator.instance.updateAudioOnly(state.audioOnly);
      _rememberPosition(state, videoId);
    } else if (state.queueSize == 0) {
      // Bildirimdeki kapat düğmesi oynatmayı bitirdi: mini oynatıcı da
      // ekranda kalmasın.
      PlaybackCoordinator.instance.handleStoppedExternally();
    }
  });

  // Televizyonda telefondan gelen videoları karşıla.
  //
  // Yalnızca televizyonda: telefon gönderen taraf, orada ağ dinlemek boşuna.
  if (TvMode.isTv.value) {
    CastReceiver.instance.onOpenRequested = _openCastedVideo;
    await CastReceiver.instance.start();
  }

  runApp(const AkisApp());
}

/// Telefondan gelen video televizyonda açılırken kullanılır.
///
/// Oynatma ekranı ZATEN açıksa yeni bir kopya açılmaz: [PlaybackCoordinator]
/// çalanı değiştirdiğinde açık ekran kendiliğinden yeni videoyu gösterir.
/// İkinci bir ekran açmak, geri tuşunda üst üste yığılmış oynatıcılar
/// bırakırdı.
///
/// [attempt]: uygulama televizyonda KAPALIYKEN yayın geldiğinde, isteği
/// karşılayan servis uygulamayı açıyor ve istek gezinme ağacı kurulmadan
/// önce buraya ulaşabiliyor. Bağlam henüz yoksa istek atılmıyor, birkaç kez
/// yeniden deneniyor — yoksa "televizyonda uygulama açıldı ama video
/// açılmadı" gibi görünüyordu.
/// Yarım bırakılan konumu kaydeder — "kaldığın yerden devam" bunu okuyor.
///
/// Uygulamanın kapanışını beklemek İŞE YARAMIYOR: süreç sistem tarafından
/// öldürüldüğünde hiçbir kanca çalışmıyor ve konum kaybolurdu. Bunun yerine
/// oynatma sürerken düzenli aralıklarla yazılıyor; en kötü ihtimalle birkaç
/// saniyelik bir sapma oluyor.
///
/// Yazım seyreltiliyor: durum akışı saniyede birkaç kez tikliyor ve her tikte
/// diske yazmanın karşılığı yok.
void _rememberPosition(PlaybackState state, String videoId) {
  // Canlı yayında "kalınan yer" diye bir şey yok.
  if (state.isLive || !state.isPlaying) return;
  final now = DateTime.now();
  if (now.difference(_lastPositionSave) < _positionSaveGap) return;
  _lastPositionSave = now;
  LibraryStore.instance.recordPosition(
    videoId,
    state.position.inMilliseconds,
    state.duration?.inMilliseconds,
  );
}

DateTime _lastPositionSave = DateTime.fromMillisecondsSinceEpoch(0);
const _positionSaveGap = Duration(seconds: 5);

void _openCastedVideo(String videoId, {int attempt = 0}) {
  if (isPlayerOpen) return;
  final context = appNavigatorKey.currentContext;
  if (context != null) {
    openPlayer(context, videoId);
    return;
  }
  // Sonsuza kadar denemiyoruz: gerçekten kurulamayan bir arayüzde bu
  // bitmeyen bir zamanlayıcı döngüsü olurdu.
  if (attempt >= _castOpenMaxAttempts) {
    debugPrint('cast: oynatma ekranı açılamadı, gezinme hazır değil');
    return;
  }
  Timer(
    _castOpenRetryDelay,
    () => _openCastedVideo(videoId, attempt: attempt + 1),
  );
}

/// Gezinme ağacının kurulmasını beklerken denenecek en fazla tekrar sayısı.
/// [_castOpenRetryDelay] ile birlikte ~3 saniye eder; soğuk açılışta arayüzün
/// hazır olması için fazlasıyla yeterli.
const int _castOpenMaxAttempts = 30;
const Duration _castOpenRetryDelay = Duration(milliseconds: 100);

/// Yayın isteği bir widget'tan değil, ağdan geliyor: ekranı açmak için
/// bağlamsız bir gezinme noktası gerekiyor.
final appNavigatorKey = GlobalKey<NavigatorState>();

class AkisApp extends StatelessWidget {
  const AkisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'oLusTifF',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.redAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Televizyonda arayüzün kenarlarından pay BIRAKILMIYOR.
      //
      // Bir zamanlar overscan (bazı televizyonların görüntünün kenarlarını
      // kırpması) için pay bırakılıyordu; ama denenen cihazlarda kırpma yok ve
      // pay, uygulamayı "ekrana sığmamış" gösteriyordu — çevresinde siyah bir
      // çerçeve kalıyordu.
      home: const HomeScreen(),
    );
  }
}
