import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/playback_client.dart';
import '../playback/ui_channel.dart';
import 'cast_client.dart';
import 'cast_discovery.dart';
import 'cast_protocol.dart';
import '../i18n/lang.dart';

/// "Şu an televizyona mı gönderiyoruz" durumunun tek sahibi.
///
/// Telefon tarafında yaşar. Yayın açıkken telefondaki oynatma DURDURULUR
/// (aynı sesin iki yerden gelmesi kullanıcıya arıza gibi görünüyor) ve
/// ekrandaki kontroller televizyona komut göndermeye başlar.
class CastController extends ChangeNotifier {
  CastController({
    CastDiscovery discovery = const CastDiscovery(),
    CastClient Function(CastDevice)? clientFactory,
    Duration pollInterval = const Duration(seconds: 2),
  })  : _discovery = discovery,
        _clientFactory = clientFactory ?? CastClient.new,
        _pollInterval = pollInterval;

  static CastController _instance = CastController();

  /// Uygulama genelinde tek yayın oturumu. Oynatma isteği nereden gelirse
  /// gelsin buraya bakıyor; iki ayrı yerde durum tutulsaydı "kontrol
  /// televizyonda, ses telefonda" gibi ayrışmalar kaçınılmaz olurdu.
  static CastController get instance => _instance;

  /// Testlerde sahte bir oturum kurabilmek için.
  @visibleForTesting
  static void overrideInstance(CastController controller) {
    _instance = controller;
  }

  @visibleForTesting
  static void resetInstance() {
    _instance = CastController();
  }

  final CastDiscovery _discovery;
  final CastClient Function(CastDevice) _clientFactory;
  final Duration _pollInterval;

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
  /// Televizyonun ses ölçeği 0..100; bu oran orada tam 2 birime denk geliyor.
  /// Cihazın kendi kademesi (1 birim) fazla küçük, %5 ise fazla kabaydı.
  /// Televizyondaki karşılığıyla aynı tutuluyor (bkz. CastReceiver.kt).
  static const double volumeStep = 0.02;

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

    // BAŞKA bir televizyona geçiliyorsa eskisi susturulur: kullanıcı artık
    // kumanda edemediği bir cihazı çalar hâlde bırakmamalı.
    final previous = _device;
    if (previous != null && previous != target) {
      await _send(CastCommand.stop);
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
      // Ses seviyesi videodan videoya değişmiyor; sıfırlamak kaydırıcıyı her
      // parça değişiminde bir yoklama boyunca kaybediyordu.
      volume: _remoteState?.volume,
      isMuted: _remoteState?.isMuted ?? false,
    );
    _lastError = null;
    notifyListeners();

    // Telefonu susturmak başarısız olsa bile (kanal hatası) yayın kurulmuş
    // sayılmalı: yoklama ve ses tuşları bağlanmazsa kullanıcı kopmayı hiç
    // fark edemez ve ses tuşları yanlış cihazı yönetir.
    try {
      await PlaybackClient.shared.pause();
    } catch (e) {
      debugPrint('cast: telefon duraklatılamadı: $e');
    }
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
  ///
  /// Komut televizyona ULAŞMAZSA false döner ve [lastError] doldurulur:
  /// kullanıcı "kestim" sanıp televizyonu çalar hâlde bırakmamalı. Yayın yine
  /// de kapatılıyor — ulaşılamayan bir televizyonun kumandasını açık tutmanın
  /// anlamı yok.
  Future<bool> stopRemote() async {
    final name = _device?.name;
    final delivered = await _send(CastCommand.stop);
    await disconnect();
    if (!delivered) {
      _lastError = tr(
          '${name ?? "Televizyon"} durdurulamadı; '
              'oynatma orada sürüyor olabilir.',
          'Could not stop ${name ?? "the TV"}; '
              'playback may still be running there.');
      notifyListeners();
    }
    return delivered;
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

  /// Testlerde televizyonun bildirdiği durumu taklit eder.
  @visibleForTesting
  void applyRemoteStateForTest(CastRemoteState state) {
    _remoteState = state;
    notifyListeners();
  }

  /// Komutu gönderir; televizyona ulaştıysa true döner.
  Future<bool> _send(
    String action, {
    Duration? position,
    double? volume,
  }) async {
    final client = _client;
    if (client == null) return false;
    try {
      await client.command(action, position: position, volume: volume);
      // Kullanıcı düğmeye bastığında arayüz beklemeden tepki vermeli;
      // yoklama saniyeler sonra geliyor.
      _applyOptimistic(action, position, volume);
      return true;
    } on CastException catch (e) {
      _lastError = e.message;
      notifyListeners();
      return false;
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
    _poll = Timer.periodic(_pollInterval, (_) async {
      final client = _client;
      if (client == null) return;
      final state = await client.remoteState();
      // Cevap gelene kadar oturum kapanmış ya da başka bir televizyona
      // geçilmiş olabilir; geç gelen sonuç kapanmış oturumu diriltmemeli.
      if (!identical(client, _client)) return;
      if (state == null) {
        // Tek bir kayıp paket oturumu bitirmez; ısrarla cevapsız kalması
        // televizyonun gittiği anlamına gelir.
        if (++_missedPolls < _maxMissedPolls) return;
        final name = _device?.name;
        await disconnect();
        _lastError = tr('${name ?? "Televizyon"} bağlantısı koptu.',
            'Lost connection to ${name ?? "the TV"}.');
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
    // Bırakılmazsa native yönlendirme açık kalıyor ve ses tuşuna basıldığında
    // atılmış bir dinleyici çağrılıyor.
    _bindVolumeKeys(false);
    _poll?.cancel();
    _client?.close();
    super.dispose();
  }
}
