import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../playback/playback_client.dart';
import '../playback/playback_coordinator.dart';
import 'cast_protocol.dart';

/// Televizyon tarafındaki alıcı.
///
/// Ağı dinleyen kısım NATIVE tarafta (bkz. `cast/CastReceiver.kt`): gelen
/// istek uygulamayı öne getirmek zorunda ve bunu yalnızca native taraf
/// yapabilir. Burası, native'in ilettiği isteği mevcut oynatma akışına
/// bağlar — yani telefondan gelen bir video, televizyonda kumandayla
/// açılmış gibi aynı yoldan oynar.
class CastReceiver {
  CastReceiver._();

  static final CastReceiver instance = CastReceiver._();

  static const _channel = MethodChannel('olustiff/cast');

  /// Yayın isteğiyle bir video açılması gerektiğinde çağrılır.
  /// Ekranı açmak arayüzün işi; burası oynatmayı başlatır.
  void Function(String videoId)? onOpenRequested;

  StreamSubscription<PlaybackState>? _stateSubscription;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);

  bool _started = false;

  /// Alıcıyı başlatır. Yalnızca televizyonda çağrılmalı.
  ///
  /// Hata fırlatmaz: alıcı açılamazsa (port dolu, ağ yok) televizyon
  /// uygulaması normal çalışmaya devam etmeli — yayın yalnızca bir ek özellik.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      final ready = await _channel.invokeMethod<bool>('startReceiver');
      if (ready != true) throw StateError('alıcı hazır değil');
    } catch (e) {
      // Bayrak GERİ ALINIYOR: yoksa başarısız bir başlatmadan sonra tekrar
      // denemek imkânsız kalıyordu.
      _started = false;
      debugPrint('cast: alıcı başlatılamadı: $e');
      return;
    }

    // Telefonun "televizyonda ne çalıyor" sorusuna cevap verebilmek için
    // durum native tarafa aktarılıyor. Native, HTTP isteği geldiğinde
    // ExoPlayer'a dokunamaz (o yalnızca ana thread'den okunabilir), bu
    // yüzden son durumu hazır tutuyor.
    _stateSubscription = PlaybackClient.shared.stateStream.listen(_publish);
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'castPlay':
        final args = call.arguments as Map<Object?, Object?>? ?? const {};
        final videoId = args['videoId'] as String?;
        if (videoId == null || videoId.isEmpty) return false;
        final positionMs = (args['positionMs'] as num?)?.toInt() ?? 0;
        await _play(videoId, positionMs);
        return true;

      case 'castCommand':
        final args = call.arguments as Map<Object?, Object?>? ?? const {};
        final action = args['action'] as String?;
        final positionMs = (args['positionMs'] as num?)?.toInt();
        return _command(action, positionMs);

      default:
        return null;
    }
  }

  Future<void> _play(String videoId, int positionMs) async {
    // Sıra ÖNEMLİ: oynatma isteği önce başlatılıyor (beklenmeden), ekran
    // sonra açılıyor.
    //
    // Sebep: oynatma ekranı açılırken "bu video zaten çalıyor mu" diye
    // soruyor ve çalmıyorsa KENDİ isteğini başlatıyor. Ekranı önce açsaydık
    // ikinci bir istek doğar, kuyruk iki kez kurulur ve o istek video
    // modunu zorlamadığı için müzik içerik televizyonda sesli modda
    // açılırdı — kullanıcı "görüntü gelmedi" diyordu.
    //
    // [forceVideo]: televizyonda sesli mod diye bir senaryo yok.
    final playing = PlaybackCoordinator.instance.play(
      videoId,
      forceVideo: true,
    );
    onOpenRequested?.call(videoId);
    await playing;
    if (positionMs > 0) {
      await PlaybackClient.shared.seekTo(Duration(milliseconds: positionMs));
    }
  }

  Future<bool> _command(String? action, int? positionMs) async {
    final playback = PlaybackClient.shared;
    switch (action) {
      case CastCommand.resume:
        await playback.resume();
      case CastCommand.pause:
        await playback.pause();
      case CastCommand.seek:
        await playback.seekTo(Duration(milliseconds: positionMs ?? 0));
      case CastCommand.next:
        await PlaybackCoordinator.instance.playNext();
      case CastCommand.previous:
        await PlaybackCoordinator.instance.playPrevious();
      case CastCommand.stop:
        await PlaybackCoordinator.instance.stop();
        // Durum HEMEN temizleniyor: native kuyruk son videonun kimliğini
        // tutmaya devam ediyor ve telefon "hâlâ o çalıyor" sanıyordu.
        _publishNow(const CastRemoteState());
      default:
        // Tanımadığımız komutu sessizce yutmuyoruz: telefon "gitti" sanmasın.
        return false;
    }
    return true;
  }

  /// Durumu kısıtlama olmadan bildirir (duraksız değişimler için).
  void _publishNow(CastRemoteState state) {
    _lastPublish = DateTime.now();
    _channel
        .invokeMethod<void>('publishState', state.toJson())
        .catchError((Object e) => debugPrint('cast: durum bildirilemedi: $e'));
  }

  void _publish(PlaybackState state) {
    // Durum akışı saniyede birkaç kez geliyor; telefon saniyede bir yokluyor.
    // Her olayı native'e taşımak boşuna kanal trafiği olurdu.
    final now = DateTime.now();
    if (now.difference(_lastPublish) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastPublish = now;

    final coordinator = PlaybackCoordinator.instance;
    final remote = CastRemoteState(
      videoId: state.currentVideoId ?? coordinator.details?.videoId,
      title: coordinator.details?.title ?? coordinator.pending?.title,
      position: state.position,
      duration: state.duration,
      isPlaying: state.isPlaying,
    );
    _channel.invokeMethod<void>('publishState', remote.toJson()).catchError((
      Object e,
    ) {
      debugPrint('cast: durum bildirilemedi: $e');
    });
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    _started = false;
  }
}
