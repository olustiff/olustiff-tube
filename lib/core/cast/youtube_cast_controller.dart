import 'package:flutter/foundation.dart';

import '../playback/playback_client.dart';
import 'cast_channel.dart';
import 'cast_protocol.dart' show CastException;
import 'dial_discovery.dart';
import 'youtube_cast.dart';
import 'youtube_cast_protocol.dart';

/// "Televizyonun KENDİ YouTube'una gönderiyoruz" durumunun sahibi.
///
/// [CastController]'dan ayrı duruyor ve onu hiç bilmiyor: o, iki uçta da
/// bizim uygulamamız varken çalışan kendi protokolümüz; bu ise televizyonda
/// oLusTifF KURULU DEĞİLKEN çalışan yol. Tek sınıfta birleştirmek, her
/// komutun hangi protokole gideceğini dallandıran bir yapı doğururdu.
///
/// ## Ne sunuluyor, ne sunulmuyor — ve neden
///
/// Sunulan: video gönderme, oynat, duraklat, önceki/sonraki, ses, durdurma.
/// Hepsi gerçek cihazda doğrulandı.
///
/// SUNULMAYAN: konum çubuğu ve ileri/geri sarma. Televizyondaki YouTube'un
/// o an nerede olduğunu okumak, Lounge'ın uzun yoklamalı olay akışını
/// işlemeyi gerektiriyor; o akış olmadan gösterilecek her konum bir TAHMİN
/// olurdu. Kullanıcı televizyonun kumandasına dokunduğu anda tahmin kayar ve
/// ekranda yanlış bir yer görünür. Yanlış çalışan bir çubuk, olmayandan
/// kötü — bu yüzden hiç gösterilmiyor.
///
/// Aynı sebeple oynat/duraklat TEK bir düğme değil, İKİ ayrı düğme: hangi
/// durumda olduğumuzu bilmediğimiz için "şu an çalıyor" diye bir şey iddia
/// etmiyoruz; iki düğme de her zaman ne yaptığını yazdığı işi yapıyor.
class YouTubeCastController extends ChangeNotifier {
  YouTubeCastController({DialDiscovery discovery = const DialDiscovery()})
      : _discovery = discovery;

  static YouTubeCastController _instance = YouTubeCastController();

  static YouTubeCastController get instance => _instance;

  @visibleForTesting
  static void overrideInstance(YouTubeCastController controller) {
    _instance = controller;
  }

  @visibleForTesting
  static void resetInstance() {
    _instance = YouTubeCastController();
  }

  final DialDiscovery _discovery;

  CastChannel? _channel;
  LoungeSessionClient? _lounge;

  YouTubeCastDevice? _device;

  /// Yayının gittiği televizyon; kapalıysa null.
  YouTubeCastDevice? get device => _device;
  bool get isCasting => _device != null;

  /// Televizyonda açılan videonun başlığı (telefondan bilinen ad).
  String? _title;
  String? get title => _title;

  String? _thumbnailUrl;
  String? get thumbnailUrl => _thumbnailUrl;

  /// Televizyonun ses seviyesi (0..1); okunamadıysa null.
  ///
  /// Bu değer Lounge'dan DEĞİL Cast kanalından geliyor — yani yerel ağdan ve
  /// gerçek. Kaydırıcının gösterilmesinin sebebi bu: gösterdiği şey tahmin
  /// değil.
  double? _volume;
  double? get volume => _volume;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  bool _busy = false;

  /// Bir komut sürüyor mu (arayüz düğmeleri kilitlensin diye).
  bool get isBusy => _busy;

  String? _lastError;
  String? get lastError => _lastError;

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// Ağdaki, kendi YouTube'u olan televizyonları arar.
  Future<List<YouTubeCastDevice>> search() => _discovery.discover();

  /// Videoyu televizyonun kendi YouTube uygulamasında açar.
  ///
  /// Sıralama önemli: önce televizyonda video AÇILDIĞINI görüyoruz, sonra
  /// telefonu susturuyoruz. Tersi olsaydı bağlantı kurulamadığında kullanıcı
  /// hem susmuş bir telefonla hem de boş bir televizyonla kalırdı.
  Future<bool> castTo(
    YouTubeCastDevice target, {
    required String videoId,
    required String title,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) async {
    _busy = true;
    _lastError = null;
    notifyListeners();

    try {
      // Aynı televizyona yeniden gönderiliyorsa kanal korunuyor: her videoda
      // YouTube'u kapatıp açmak ekranı karartıyordu.
      var channel = _channel;
      var lounge = _lounge;
      if (channel == null || _device != target) {
        await _teardown();
        channel = await CastChannel.connect(target.host);
        final screenId = await channel.launchYouTube();
        lounge = await LoungeSessionClient.open(screenId);
        _channel = channel;
        _lounge = lounge;
      }

      await lounge!.playVideo(videoId, position: position);

      _device = target;
      _title = title;
      _thumbnailUrl = thumbnailUrl;
    } on CastException catch (e) {
      await _teardown();
      _device = null;
      _lastError = e.message;
      _busy = false;
      notifyListeners();
      return false;
    }

    // Ses seviyesi yayın kurulduktan sonra okunuyor; okunamazsa kaydırıcı
    // hiç gösterilmiyor.
    _volume = null;
    unawaited(_refreshVolume());

    // Telefonu susturmak başarısız olsa bile yayın kurulmuş sayılmalı:
    // televizyonda video zaten açıldı.
    try {
      await PlaybackClient.shared.pause();
    } catch (e) {
      debugPrint('youtube-cast: telefon duraklatılamadı: $e');
    }

    _busy = false;
    notifyListeners();
    return true;
  }

  /// Yayın açıkken televizyondaki videoyu değiştirir.
  Future<bool> sendCurrent({
    required String videoId,
    required String title,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) async {
    final target = _device;
    if (target == null) return false;
    return castTo(
      target,
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      position: position,
    );
  }

  Future<void> play() => _send((l) => l.play());

  Future<void> pause() => _send((l) => l.pause());

  Future<void> next() => _send((l) => l.next());

  Future<void> previous() => _send((l) => l.previous());

  /// Televizyonun sesini ayarlar.
  ///
  /// Cast kanalından gidiyor (yerel ağ): Lounge'ın ses komutu yalnızca
  /// YouTube'un kendi oynatıcı sesini değiştiriyor, kullanıcının beklediği
  /// ise televizyonun ana sesi.
  Future<void> setVolume(double value) async {
    final channel = _channel;
    if (channel == null) return;
    final level = value.clamp(0.0, 1.0);
    channel.setVolume(level);
    _volume = level;
    _isMuted = false;
    notifyListeners();
    await _refreshVolume();
  }

  Future<void> toggleMute() async {
    final channel = _channel;
    if (channel == null) return;
    final muted = !_isMuted;
    channel.setMuted(muted);
    _isMuted = muted;
    notifyListeners();
    await _refreshVolume();
  }

  /// Televizyondaki oynatmayı durdurup yayını kapatır.
  Future<void> stopRemote() async {
    final channel = _channel;
    final sessionId = channel?.youTubeSessionId;
    try {
      await _lounge?.stopVideo();
    } on CastException catch (e) {
      debugPrint('youtube-cast: durdurulamadı: $e');
    }
    // Oynatmayı durdurmak YouTube'u kapatmıyor; kullanıcı "bitir" dediğinde
    // televizyonun boşta ekrana dönmesini bekliyor.
    if (channel != null && sessionId != null) {
      channel.stopYouTube(sessionId);
    }
    await disconnect();
  }

  /// Yayını kapatır; televizyondaki oynatmaya DOKUNMAZ.
  ///
  /// Kullanıcı çoğu zaman "telefonu bırakıp televizyonda izlemeye devam"
  /// istiyor.
  Future<void> disconnect() async {
    await _teardown();
    _device = null;
    _title = null;
    _thumbnailUrl = null;
    _volume = null;
    _isMuted = false;
    notifyListeners();
  }

  Future<void> _send(Future<void> Function(LoungeSessionClient) action) async {
    final lounge = _lounge;
    if (lounge == null) return;
    try {
      await action(lounge);
    } on CastException catch (e) {
      _lastError = e.message;
      notifyListeners();
    }
  }

  Future<void> _refreshVolume() async {
    final channel = _channel;
    if (channel == null) return;
    final reading = await channel.readVolume();
    // Cevap gelene kadar oturum kapanmış olabilir; geç gelen sonuç kapanmış
    // oturumu diriltmemeli.
    if (reading == null || !identical(channel, _channel)) return;
    _volume = reading.level;
    _isMuted = reading.muted;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _lounge?.close();
    _lounge = null;
    await _channel?.close();
    _channel = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}

/// `unawaited` için küçük yardımcı — `dart:async` içe aktarmadan.
void unawaited(Future<void> future) {
  future.catchError((Object e) {
    debugPrint('youtube-cast: arka plan işi başarısız: $e');
  });
}
