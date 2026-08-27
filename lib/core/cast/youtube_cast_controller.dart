import 'dart:async' show StreamSubscription, Timer;

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
/// ## Komutlar İKİ ayrı yoldan gidiyor — sebebi ölçüm
///
/// - **Video göndermek** (`setPlaylist`) Lounge'dan, yani internet üzerinden.
///   Başka yolu yok: alıcı standart Cast `LOAD` komutunu reddediyor.
/// - **Oynat, duraklat, sarma** YEREL Cast kanalından
///   ([CastNamespace.media]). Alıcının bu ad alanını kabul ettiği gerçek
///   cihazda ölçüldü ve fark büyük:
///
///   | komut | Lounge | yerel kanal |
///   |-------|--------|-------------|
///   | oynat/duraklat | 365–1771 ms | 0–1 ms |
///   | sarma | 324 ms | 20 ms |
///
///   Lounge'dan giden bir komut telefondan Google'a, oradan televizyona
///   gidiyor; yereldeki paket ise ağdan hiç çıkmıyor. Saniyeye varan
///   gecikme kumandayı "donuk" hissettiriyordu.
///
/// Yerel kanal yalnızca hızı değil, DURUMU da veriyor: televizyonun bildirdiği
/// oynatma durumu, konum ve süre. Bu yüzden artık tek bir oynat/duraklat
/// düğmesi ve çalışan bir konum çubuğu var — gösterilen değerler tahmin
/// değil, televizyonun kendi söylediği değerler. Kullanıcı televizyonun
/// kumandasına dokunduğunda alıcı kendiliğinden bildiriyor, ekran kaymıyor.
///
/// Durum okunamayan cihazlarda ([status] null) komutlar Lounge'a düşüyor ve
/// arayüz eski hâline — iki ayrı düğme, çubuk yok — dönüyor. Yarım bilgiyle
/// çubuk göstermek, hiç göstermemekten kötü.
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

  /// Televizyonun bildirdiği son durum; okunamıyorsa null.
  CastMediaStatus? _status;
  CastMediaStatus? get status => _status;

  /// [_status]'un alındığı an — aradaki konumu ilerletmek için.
  DateTime? _statusAt;

  StreamSubscription<CastMediaStatus>? _statusSubscription;
  Timer? _statusTimer;

  /// Yerel kanaldan kumanda edilebiliyor mu (tek düğme + konum çubuğu).
  bool get hasLiveStatus => _status != null;

  /// Televizyonda video çalıyor mu; bilinmiyorsa null.
  bool? get isPlaying => _status?.isPlaying;

  Duration? get duration => _status?.duration;

  /// Televizyonun o anki konumu.
  ///
  /// İki durum arası SAATLE ilerletiliyor: alıcı düzenli aralıklarla konum
  /// yollamıyor, yalnızca bir şey değiştiğinde bildiriyor. İlerletmesek çubuk
  /// her yoklama arasında donar, kullanıcı takılıyor sanırdı. İlerletme
  /// yalnızca oynatma sürerken yapılıyor ve her yoklamada gerçek değerle
  /// yeniden hizalanıyor, yani kayma birikmiyor.
  Duration? get position {
    final status = _status;
    final at = _statusAt;
    if (status == null || at == null) return null;
    if (!status.isPlaying) return status.position;
    final moved = status.position + DateTime.now().difference(at);
    final total = status.duration;
    if (total != null && moved > total) return total;
    return moved;
  }

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
        _watchStatus(channel);
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

  /// Televizyonda oynatmayı sürdürür.
  Future<void> play() async {
    final session = _status?.mediaSessionId;
    final channel = _channel;
    if (session != null && channel != null) {
      channel.playMedia(session);
      // Durum İYİMSER güncelleniyor: alıcının bildirimi 1–2 ms sonra gelse
      // bile düğmenin o ana kadar eski hâlini göstermesi "basmadı" hissi
      // veriyordu. Gelen gerçek bildirim bunun üstüne yazıyor.
      _assumePlaying(true);
      return;
    }
    return _send((l) => l.play());
  }

  /// Televizyondaki videoyu duraklatır.
  Future<void> pause() async {
    final session = _status?.mediaSessionId;
    final channel = _channel;
    if (session != null && channel != null) {
      channel.pauseMedia(session);
      _assumePlaying(false);
      return;
    }
    return _send((l) => l.pause());
  }

  /// Televizyondaki videoyu [position] konumuna sarar.
  ///
  /// Yalnızca [hasLiveStatus] doğruyken çağrılmalı: Lounge'ın sarma komutu
  /// çalışıyor ama nereden nereye sarıldığını göremediğimiz için arayüzde
  /// karşılığı olan bir çubuk çizilemiyor.
  Future<void> seekTo(Duration position) async {
    final session = _status?.mediaSessionId;
    final channel = _channel;
    if (session == null || channel == null) return;
    channel.seekMedia(session, position);
    // Çubuğun bırakıldığı yerde kalması için konum hemen kabul ediliyor;
    // alıcı gerçek değeri birazdan bildiriyor.
    _applyStatus(
      CastMediaStatus(
        mediaSessionId: session,
        playerState: _status!.playerState,
        position: position,
        duration: _status!.duration,
        title: _status!.title,
      ),
    );
  }

  Future<void> next() => _send((l) => l.next());

  Future<void> previous() => _send((l) => l.previous());

  /// Yerel komuttan hemen sonra beklenen durumu yazar.
  void _assumePlaying(bool playing) {
    final status = _status;
    if (status == null) return;
    _applyStatus(
      CastMediaStatus(
        mediaSessionId: status.mediaSessionId,
        // Konum GETTER'dan okunuyor: duraklatırken ekranda duran değer,
        // en son bildirimin değeri değil, o ana kadar ilerlemiş olan.
        playerState: playing ? 'PLAYING' : 'PAUSED',
        position: position ?? status.position,
        duration: status.duration,
        title: status.title,
      ),
    );
  }

  /// Televizyonun durumunu izlemeye başlar.
  ///
  /// İKİ kaynak birden dinleniyor ve ikisi de gerekli:
  /// - Alıcının kendiliğinden gönderdiği bildirimler — kullanıcı televizyonun
  ///   kumandasıyla duraklattığında ekranın kaymamasını sağlıyor.
  /// - Saniyede bir yoklama — alıcı düzenli konum bildirmiyor, yalnızca bir
  ///   şey değiştiğinde konuşuyor; yoklamasız çubuk gerçekle hiç
  ///   hizalanmazdı. Yerel ağda bir tur ~1 ms sürüyor, yani bedeli yok.
  void _watchStatus(CastChannel channel) {
    _statusSubscription?.cancel();
    _statusSubscription = channel.mediaStatuses.listen(
      _applyStatus,
      onError: (Object _) {},
    );
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _channel?.requestMediaStatus(),
    );
    channel.requestMediaStatus();
  }

  void _applyStatus(CastMediaStatus status) {
    _status = status.mergeOnto(_status);
    _statusAt = DateTime.now();
    notifyListeners();
  }

  void _clearStatus() {
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _statusTimer?.cancel();
    _statusTimer = null;
    _status = null;
    _statusAt = null;
  }

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
    _clearStatus();
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
