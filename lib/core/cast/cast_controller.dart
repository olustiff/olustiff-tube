import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/playback_client.dart';
import '../playback/ui_channel.dart';
import 'cast_client.dart';
import 'cast_discovery.dart';
import 'cast_protocol.dart';

/// "Şu an televizyona mı gönderiyoruz" durumunun tek sahibi.
///
/// Telefon tarafında yaşar. Yayın açıkken telefondaki oynatma DURDURULUR
/// (aynı sesin iki yerden gelmesi kullanıcıya arıza gibi görünüyor) ve
/// ekrandaki kontroller televizyona komut göndermeye başlar.
class CastController extends ChangeNotifier {
  CastController({
    CastDiscovery discovery = const CastDiscovery(),
    CastClient Function(CastDevice)? clientFactory,
  })  : _discovery = discovery,
        _clientFactory = clientFactory ?? CastClient.new;

  static final CastController instance = CastController();

  final CastDiscovery _discovery;
  final CastClient Function(CastDevice) _clientFactory;

  CastClient? _client;
  Timer? _poll;

  /// Üst üste kaçıncı yoklamanın cevapsız kaldığı.
  ///
  /// Tek bir kayıp paket yüzünden kullanıcının kumandasını elinden almak
  /// yanlış olur; ama televizyon gerçekten gittiyse (kapandı, uygulama
  /// kapandı, ağ koptu) telefon bunu fark edip normal moda dönmeli — yoksa
  /// kullanıcı ölü bir kumandayla kalıyor.
  int _missedPolls = 0;

  /// Bu kadar yoklama üst üste cevapsız kalırsa oturum bitmiş sayılır.
  static const _maxMissedPolls = 3;

  /// Ses düğmelerinin bir basışta ne kadar oynattığı.
  ///
  /// Televizyonun kendi kademesi (0..100 aralığında 1 birim) çok küçük:
  /// kullanıcı sesi duyulur şekilde açmak için yirmi kez basmak zorunda
  /// kalırdı.
  static const double volumeStep = 0.05;

  CastDevice? _device;

  /// Yayının gittiği televizyon; yayın kapalıysa null.
  CastDevice? get device => _device;
  bool get isCasting => _device != null;

  CastRemoteState? _remoteState;

  /// Televizyonda çalanın son bilinen hâli. Yoklamayla güncellenir.
  CastRemoteState? get remoteState => _remoteState;

  /// Televizyonun bildirdiği ses seviyesi (0..1); bilinmiyorsa null.
  double? get volume => _remoteState?.volume;

  bool get isMuted => _remoteState?.isMuted ?? false;

  bool _searching = false;
  bool get isSearching => _searching;

  /// Kullanıcıya gösterilecek son hata. Okunduktan sonra
  /// [clearError] ile temizlenir; aynı hata tekrar tekrar gösterilmez.
  String? _lastError;
  String? get lastError => _lastError;

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// Ağdaki televizyonları arar.
  Future<List<CastDevice>> search() async {
    _searching = true;
    notifyListeners();
    try {
      return await _discovery.discover();
    } finally {
      _searching = false;
      notifyListeners();
    }
  }

  /// Videoyu televizyona gönderir ve telefondaki oynatmayı durdurur.
  ///
  /// Sıralama önemli: önce televizyonun isteği KABUL ettiğini görüyoruz,
  /// sonra telefonu susturuyoruz. Tersi olsaydı televizyona ulaşılamadığında
  /// kullanıcı hem susmuş bir telefonla hem de boş bir televizyonla kalırdı.
  Future<bool> castTo(
    CastDevice target, {
    required String videoId,
    required String title,
    String? artist,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) async {
    final client = _clientFactory(target);
    try {
      await client.play(
        videoId: videoId,
        title: title,
        artist: artist,
        thumbnailUrl: thumbnailUrl,
        position: position,
      );
    } on CastException catch (e) {
      client.close();
      _lastError = e.message;
      notifyListeners();
      return false;
    }

    _client?.close();
    _client = client;
    _device = target;
    _missedPolls = 0;
    _remoteState = CastRemoteState(
      videoId: videoId,
      title: title,
      position: position,
      isPlaying: true,
    );
    _lastError = null;
    notifyListeners();

    await PlaybackClient.shared.pause();
    _bindVolumeKeys(true);
    _startPolling();
    return true;
  }

  /// Televizyondaki videoyu değiştirir (yayın açıkken yeni bir videoya
  /// dokunulduğunda). Bağlantı korunur.
  Future<bool> sendCurrent({
    required String videoId,
    required String title,
    String? artist,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) async {
    final target = _device;
    if (target == null) return false;
    return castTo(
      target,
      videoId: videoId,
      title: title,
      artist: artist,
      thumbnailUrl: thumbnailUrl,
      position: position,
    );
  }

  Future<void> resume() => _send(CastCommand.resume);

  Future<void> pause() => _send(CastCommand.pause);

  Future<void> next() => _send(CastCommand.next);

  Future<void> previous() => _send(CastCommand.previous);

  Future<void> seekTo(Duration position) =>
      _send(CastCommand.seek, position: position);

  /// Televizyonun sesini mutlak olarak ayarlar (0..1).
  Future<void> setVolume(double value) =>
      _send(CastCommand.volume, volume: value.clamp(0.0, 1.0));

  /// Sesi bir kademe açar. Sessizdeyse önce sessizlikten çıkar — kullanıcı
  /// ses tuşuna bastığında beklediği budur.
  Future<void> volumeUp() => _send(CastCommand.volumeUp);

  Future<void> volumeDown() => _send(CastCommand.volumeDown);

  Future<void> toggleMute() => _send(CastCommand.mute);

  /// Televizyonda çalanı durdurup yayını kapatır.
  Future<void> stopRemote() async {
    await _send(CastCommand.stop);
    await disconnect();
  }

  /// Yayını kapatır; televizyondaki oynatmaya DOKUNMAZ.
  ///
  /// Kullanıcı çoğu zaman "telefonu bırakıp televizyonda izlemeye devam"
  /// istiyor; bağlantıyı kesmenin televizyonu da susturması sürpriz olurdu.
  Future<void> disconnect() async {
    _bindVolumeKeys(false);
    _poll?.cancel();
    _poll = null;
    _client?.close();
    _client = null;
    _device = null;
    _remoteState = null;
    notifyListeners();
  }

  /// Telefonun fiziksel ses tuşlarını televizyona bağlar ya da bırakır.
  ///
  /// Hata yutuluyor: native taraf bu yöntemi tanımıyorsa (eski kurulum)
  /// ekrandaki kaydırıcı yine çalışıyor, yalnızca yan tuşlar telefonun kendi
  /// sesini değiştiriyor.
  void _bindVolumeKeys(bool enabled) {
    final ui = UiChannel.instance;
    ui.onCastVolumeKey = enabled
        ? (direction) => direction == 'up' ? volumeUp() : volumeDown()
        : null;
    ui.setCastVolumeKeys(enabled).catchError((Object e) {
      debugPrint('cast: ses tuşları yönlendirilemedi: $e');
    });
  }

  Future<void> _send(String action, {Duration? position, double? volume}) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.command(action, position: position, volume: volume);
      // Kullanıcı düğmeye bastığında arayüz beklemeden tepki vermeli;
      // yoklama saniyeler sonra geliyor.
      _applyOptimistic(action, position, volume);
    } on CastException catch (e) {
      _lastError = e.message;
      notifyListeners();
    }
  }

  /// Komutun beklenen sonucunu yerel duruma hemen yansıtır.
  void _applyOptimistic(String action, Duration? position, double? volume) {
    final state = _remoteState;
    if (state == null) return;
    final current = state.volume;
    _remoteState = switch (action) {
      CastCommand.resume => state.copyWith(isPlaying: true),
      CastCommand.pause => state.copyWith(isPlaying: false),
      CastCommand.seek => state.copyWith(position: position ?? state.position),
      CastCommand.volume => state.copyWith(volume: volume, isMuted: false),
      // Ses seviyesi henüz bilinmiyorsa tahmin yürütmüyoruz; bir sonraki
      // yoklama gerçek değeri getirecek.
      CastCommand.volumeUp => current == null
          ? state
          : state.copyWith(
              volume: (current + volumeStep).clamp(0.0, 1.0),
              isMuted: false,
            ),
      CastCommand.volumeDown => current == null
          ? state
          : state.copyWith(volume: (current - volumeStep).clamp(0.0, 1.0)),
      CastCommand.mute => state.copyWith(isMuted: !state.isMuted),
      _ => state,
    };
    notifyListeners();
  }

  void _startPolling() {
    _poll?.cancel();
    _missedPolls = 0;
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final client = _client;
      if (client == null) return;
      final state = await client.remoteState();
      if (state == null) {
        // Tek bir kayıp paket oturumu bitirmez; ısrarla cevapsız kalması
        // televizyonun gittiği anlamına gelir.
        if (++_missedPolls < _maxMissedPolls) return;
        final name = _device?.name;
        await disconnect();
        _lastError = '${name ?? "Televizyon"} bağlantısı koptu.';
        notifyListeners();
        return;
      }
      _missedPolls = 0;
      _remoteState = state;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _client?.close();
    super.dispose();
  }
}
