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
      await _channel.invokeMethod<void>('startReceiver');
    } catch (e) {
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
    // Ekranı önce aç: çözümleme saniyeler sürebiliyor, televizyonda bu
    // sürede hiçbir şey olmaması "gitmedi" hissi veriyor.
    onOpenRequested?.call(videoId);
    await PlaybackCoordinator.instance.play(videoId);
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
      default:
        // Tanımadığımız komutu sessizce yutmuyoruz: telefon "gitti" sanmasın.
        return false;
    }
    return true;
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
