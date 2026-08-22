import 'package:flutter/services.dart';

/// Native ExoPlayer/Media3 oturumunun anlık durumu.
class PlaybackState {
  final Duration position;
  final Duration? duration;
  final Duration bufferedPosition;
  final bool isPlaying;
  final bool playWhenReady;
  final bool isBuffering;
  final bool isEnded;

  /// Kullanıcının seçtiği mod. Uygulama bunu kendiliğinden değiştirmez —
  /// sesli modda başlayan bir oynatma asla video moduna atlamaz.
  final bool audioOnly;
  final double speed;

  const PlaybackState({
    this.position = Duration.zero,
    this.duration,
    this.bufferedPosition = Duration.zero,
    this.isPlaying = false,
    this.playWhenReady = false,
    this.isBuffering = false,
    this.isEnded = false,
    this.audioOnly = false,
    this.speed = 1.0,
  });

  factory PlaybackState.fromMap(Map<Object?, Object?> map) {
    Duration ms(Object? value) =>
        Duration(milliseconds: (value as num?)?.toInt() ?? 0);

    final rawDuration = map['durationMs'] as num?;

    return PlaybackState(
      position: ms(map['positionMs']),
      duration: rawDuration == null
          ? null
          : Duration(milliseconds: rawDuration.toInt()),
      bufferedPosition: ms(map['bufferedPositionMs']),
      isPlaying: map['isPlaying'] as bool? ?? false,
      playWhenReady: map['playWhenReady'] as bool? ?? false,
      isBuffering: map['isBuffering'] as bool? ?? false,
      isEnded: map['isEnded'] as bool? ?? false,
      audioOnly: map['audioOnly'] as bool? ?? false,
      speed: (map['speed'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// Native oynatma servisinin Dart yüzü.
class PlaybackClient {
  PlaybackClient({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _method = methodChannel ?? const MethodChannel('akis/player'),
        _events = eventChannel ?? const EventChannel('akis/player_events');

  /// Uygulama genelinde paylaşılan örnek.
  ///
  /// Native tarafta tek bir player ve tek bir olay kanalı var; her ekranın
  /// kendi istemcisini kurması aynı kanala birden fazla abonelik açar ve
  /// öncekini iptal ettirir. Testlerde kendi kanallarınla ayrı bir örnek
  /// oluşturabilirsin.
  static final PlaybackClient shared = PlaybackClient();

  final MethodChannel _method;
  final EventChannel _events;

  Stream<PlaybackState>? _stateStream;

  /// Durum akışı.
  ///
  /// Aynı EventChannel'a ikinci kez abone olmak native taraftaki `onListen`'i
  /// yeniden tetikler ve önceki aboneliği iptal ettirir; bu yüzden oynatma
  /// ekranı ile mini oynatıcının paylaşabileceği TEK bir broadcast akışı
  /// önbelleğe alınıyor.
  Stream<PlaybackState> get stateStream => _stateStream ??= _events
      .receiveBroadcastStream()
      .map((e) => PlaybackState.fromMap(e as Map<Object?, Object?>))
      .asBroadcastStream();

  Future<void> play({
    required String audioUrl,
    String? videoUrl,
    required String title,
    String? artist,
    String? artworkUrl,
    required bool audioOnly,
    bool isLive = false,
  }) {
    return _method.invokeMethod<void>('play', {
      'audioUrl': audioUrl,
      'videoUrl': videoUrl,
      'title': title,
      'artist': artist,
      'artworkUrl': artworkUrl,
      'audioOnly': audioOnly,
      'isLive': isLive,
    });
  }

  /// Modu kullanıcının açık isteğiyle değiştirir; oynatma konumu korunur.
  Future<void> setAudioOnly(bool audioOnly) =>
      _method.invokeMethod<void>('setAudioOnly', {'audioOnly': audioOnly});

  Future<void> resume() => _method.invokeMethod<void>('resume');

  Future<void> pause() => _method.invokeMethod<void>('pause');

  Future<void> seekTo(Duration position) => _method
      .invokeMethod<void>('seekTo', {'positionMs': position.inMilliseconds});

  Future<void> setSpeed(double speed) =>
      _method.invokeMethod<void>('setSpeed', {'speed': speed});

  Future<void> stop() => _method.invokeMethod<void>('stop');
}
