import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cast_protocol.dart' show CastException;
import 'youtube_cast_protocol.dart';

/// Televizyonun Cast (8009/TLS) denetim kanalı.
///
/// İki iş için kullanılıyor:
/// - Televizyonun KENDİ YouTube uygulamasını başlatmak,
/// - Başlayan oturumun **screenId**'sini almak (Lounge'a giriş anahtarı).
///
/// Bunların ikisi de TAMAMEN YEREL: kayıt, hesap, anahtar gerekmiyor.
///
/// Sertifika DOĞRULANMIYOR ve bu bilinçli: Chromecast cihazları kendi
/// imzaladıkları sertifikayı sunuyor, hiçbir genel kök tarafından
/// doğrulanamaz. Bağlantı yerel ağdaki bir IP'ye gidiyor ve taşınan tek
/// şey "şu uygulamayı aç" komutu — kimlik bilgisi geçmiyor.
class CastChannel {
  CastChannel._(this._socket);

  final SecureSocket _socket;
  final _reader = CastFrameReader();
  final _messages = StreamController<CastMessage>.broadcast();

  StreamSubscription<List<int>>? _subscription;
  int _requestId = 1;

  /// Gönderen kimliği; Cast tarafında serbest bir dize.
  static const _sourceId = 'sender-0';
  static const _receiverId = 'receiver-0';

  static const _connectTimeout = Duration(seconds: 6);

  /// Bir adımın (başlatma, screenId) cevabı için beklenen üst süre.
  static const _stepTimeout = Duration(seconds: 12);

  /// Televizyona bağlanır.
  static Future<CastChannel> connect(String host) async {
    final SecureSocket socket;
    try {
      socket = await SecureSocket.connect(
        host,
        castV2Port,
        onBadCertificate: (_) => true,
        timeout: _connectTimeout,
      );
    } catch (e) {
      debugPrint('youtube-cast: $host Cast kanalı açılamadı: $e');
      throw const CastException(
        'Televizyona bağlanılamadı. Televizyon açık ve aynı Wi-Fi ağında '
        'olmalı.',
      );
    }

    final channel = CastChannel._(socket);
    channel._listen();
    channel._send(_receiverId, CastNamespace.connection, {'type': 'CONNECT'});
    return channel;
  }

  void _listen() {
    _subscription = _socket.listen(
      (chunk) {
        for (final message in _reader.add(chunk)) {
          // Kalp atışı protokolün kendi işi; üst katmanı ilgilendirmiyor.
          // Cevapsız bırakılırsa televizyon bağlantıyı birkaç saniyede
          // kapatıyor ve oturum sebepsiz düşüyor.
          if (message.namespace == CastNamespace.heartbeat) {
            if (message.json?['type'] == 'PING') {
              _send(_receiverId, CastNamespace.heartbeat, {'type': 'PONG'});
            }
            continue;
          }
          if (!_messages.isClosed) _messages.add(message);
        }
      },
      onError: (Object e) {
        debugPrint('youtube-cast: Cast kanalı hatası: $e');
        _messages.close();
      },
      onDone: _messages.close,
      cancelOnError: false,
    );
  }

  /// Televizyonun kendi YouTube uygulamasını başlatır ve oturumun
  /// screenId'sini döner.
  ///
  /// YouTube zaten açıksa yeniden başlatılmıyor — Cast tarafı aynı oturumu
  /// döndürüyor, yani kullanıcı ikinci videoyu gönderdiğinde ekran
  /// kararmıyor.
  Future<String> launchYouTube() async {
    final status = await _request(
      _receiverId,
      CastNamespace.receiver,
      {'type': 'LAUNCH', 'appId': youtubeReceiverAppId},
      accept: (message) {
        if (message.namespace != CastNamespace.receiver) return false;
        final json = message.json;
        if (json?['type'] == 'LAUNCH_ERROR') return true;
        return _findYouTubeTransport(json) != null;
      },
      onTimeout: 'Televizyonda YouTube açılamadı.',
    );

    final json = status.json;
    if (json?['type'] == 'LAUNCH_ERROR') {
      // En sık sebebi: televizyonda YouTube kurulu değil.
      throw const CastException(
        'Televizyon YouTube uygulamasını açamadı. Uygulamanın televizyonda '
        'kurulu olduğundan emin olun.',
      );
    }

    final transportId = _findYouTubeTransport(json);
    if (transportId == null) {
      throw const CastException('Televizyonda YouTube açılamadı.');
    }
    _youTubeTransportId = transportId;

    // Oturumla konuşmadan önce ona ayrıca bağlanmak gerekiyor; alıcıya
    // bağlanmış olmak yetmiyor.
    _send(transportId, CastNamespace.connection, {'type': 'CONNECT'});

    // Soru BİRKAÇ KEZ soruluyor. Sebebi bir yarış: `CONNECT` ile hemen
    // ardından gönderilen soru televizyona aynı anda ulaşıyor ve bağlantı
    // henüz kurulmadığı için soru sessizce DÜŞÜYOR — cevap hiç gelmiyor.
    // Gerçek cihazda arada bir yaşandı; tek denemede "oturum okunamadı"
    // hatası veriyordu. Yeniden sormak, beklemekten daha güvenilir: sabit
    // bir gecikme yavaş cihazlarda yetmiyor, hızlılarda boşuna bekletiyor.
    for (var attempt = 0; ; attempt++) {
      try {
        final mdx = await _request(
          transportId,
          CastNamespace.youtubeMdx,
          {'type': 'getMdxSessionStatus'},
          accept: (message) =>
              message.namespace == CastNamespace.youtubeMdx &&
              message.json?['type'] == 'mdxSessionStatus',
          onTimeout: 'Televizyondaki YouTube oturumu okunamadı.',
          timeout: const Duration(seconds: 4),
        );
        final data = mdx.json?['data'];
        final screenId = data is Map ? data['screenId'] : null;
        if (screenId is String && screenId.isNotEmpty) return screenId;
      } on CastException {
        // Son denemede hatayı yukarı bırak.
        if (attempt >= 2) rethrow;
      }
      if (attempt >= 2) {
        throw const CastException('Televizyondaki YouTube oturumu okunamadı.');
      }
    }
  }

  /// Televizyonun ses seviyesini ayarlar (0..1).
  ///
  /// Ses Lounge üzerinden DEĞİL buradan yönetiliyor: bu komut yerel ağdan
  /// gidiyor, anında etki ediyor ve televizyonun ana sesini değiştiriyor —
  /// kullanıcının ses tuşundan beklediği davranış bu.
  void setVolume(double level) {
    _notify({
      'type': 'SET_VOLUME',
      'volume': {'level': level.clamp(0.0, 1.0)},
    });
  }

  /// Sessize alır / açar.
  void setMuted(bool muted) {
    _notify({
      'type': 'SET_VOLUME',
      'volume': {'muted': muted},
    });
  }

  /// Televizyondaki YouTube'u kapatır (boşta ekrana döner).
  void stopYouTube(String sessionId) {
    _notify({'type': 'STOP', 'sessionId': sessionId});
  }

  /// Cevabı beklenmeyen bir alıcı komutu gönderir.
  ///
  /// `requestId` ŞART, cevabı beklemesek bile: televizyon kimliksiz gelen
  /// alıcı komutlarını sessizce YOK SAYIYOR. Gerçek cihazda görüldü —
  /// `SET_VOLUME` isteği 200 gibi davranıp ses hiç değişmiyordu, çünkü mesaj
  /// hiç işlenmemişti.
  void _notify(Map<String, Object?> body) {
    _send(_receiverId, CastNamespace.receiver, {
      ...body,
      'requestId': _requestId++,
    });
  }

  /// Televizyonun bildirdiği ses seviyesini okur; okunamazsa null.
  Future<({double level, bool muted})?> readVolume() async {
    try {
      final status = await _request(
        _receiverId,
        CastNamespace.receiver,
        {'type': 'GET_STATUS'},
        accept: (m) =>
            m.namespace == CastNamespace.receiver &&
            m.json?['type'] == 'RECEIVER_STATUS',
        onTimeout: 'okunamadı',
        timeout: const Duration(seconds: 4),
      );
      final volume = (status.json?['status'] as Map?)?['volume'];
      if (volume is! Map) return null;
      final level = volume['level'];
      if (level is! num) return null;
      return (level: level.toDouble(), muted: volume['muted'] == true);
    } catch (_) {
      // Ses okunamaması yayını bozmaz; arayüz kaydırıcıyı gizler.
      return null;
    }
  }

  /// Açık oturumdaki YouTube'un kimliği (durdurmak için gerekiyor).
  String? youTubeSessionId;

  /// YouTube oturumunun adresi; medya komutları buraya gidiyor.
  String? _youTubeTransportId;

  /// Televizyonun kendiliğinden gönderdiği medya durumları.
  ///
  /// Yoklamaya EK, yerine değil: alıcı kendi kumandasıyla yapılan
  /// değişiklikleri (kullanıcı televizyondan duraklattığında) buradan
  /// bildiriyor, ama düzenli aralıklarla konum yollamıyor.
  Stream<CastMediaStatus> get mediaStatuses => _messages.stream
      .where((m) => m.namespace == CastNamespace.media)
      .map((m) => parseMediaStatus(m.json))
      .where((status) => status != null)
      .cast<CastMediaStatus>();

  /// Televizyondan durumunu bildirmesini ister.
  ///
  /// Cevap BEKLENMİYOR: gelen durum zaten [mediaStatuses] akışından geçiyor,
  /// çünkü alıcı sorulmadan da bildirim gönderiyor ve iki kaynağı ayrı ayrı
  /// karşılamanın bir karşılığı yok.
  ///
  /// Ayrıca bu istek saniyede bir gönderiliyor. Cevabı tek tek beklemek,
  /// televizyon sustuğunda (uyudu, ağdan düştü) her turda bir bekleyen
  /// abonelik bırakırdı; cevapsız gönderimde biriken bir şey yok.
  void requestMediaStatus() => _media({'type': 'GET_STATUS'});

  /// Televizyondaki videoyu oynatır.
  void playMedia(int mediaSessionId) =>
      _media({'type': 'PLAY', 'mediaSessionId': mediaSessionId});

  /// Televizyondaki videoyu duraklatır.
  void pauseMedia(int mediaSessionId) =>
      _media({'type': 'PAUSE', 'mediaSessionId': mediaSessionId});

  /// Televizyondaki videoyu [position] konumuna sarar.
  void seekMedia(int mediaSessionId, Duration position) => _media({
        'type': 'SEEK',
        'mediaSessionId': mediaSessionId,
        'currentTime': position.inMilliseconds / 1000,
      });

  /// Medya komutu gönderir; cevabı beklemiyor.
  ///
  /// Beklememek bilinçli: komut yerel ağdan gidiyor ve alıcı sonucu zaten
  /// kendiliğinden bildiriyor. Cevabı beklemek arayüzü boş yere kilitlerdi —
  /// düğmenin anında tepki vermesinin sebebi bu.
  void _media(Map<String, Object?> body) {
    final transport = _youTubeTransportId;
    if (transport == null) return;
    _send(transport, CastNamespace.media, {
      ...body,
      'requestId': _requestId++,
    });
  }

  String? _findYouTubeTransport(Map<String, Object?>? json) {
    final status = json?['status'];
    if (status is! Map) return null;
    final applications = status['applications'];
    if (applications is! List) return null;
    for (final app in applications) {
      if (app is! Map) continue;
      if (app['appId'] != youtubeReceiverAppId) continue;
      final transport = app['transportId'];
      final session = app['sessionId'];
      if (session is String) youTubeSessionId = session;
      if (transport is String && transport.isNotEmpty) return transport;
    }
    return null;
  }

  /// İstek gönderir ve [accept] doğru diyene kadar bekler.
  ///
  /// `requestId` eşlemesi yerine içerik eşlemesi kullanılıyor: televizyon
  /// bazı cevapları `requestId: 0` ile (kendiliğinden durum bildirimi olarak)
  /// gönderiyor ve yalnızca kimliğe bakan bir bekleyiş sonsuza kadar
  /// bekliyordu.
  Future<CastMessage> _request(
    String destination,
    String namespace,
    Map<String, Object?> payload, {
    required bool Function(CastMessage) accept,
    required String onTimeout,
    Duration? timeout,
  }) async {
    // Dinlemeye göndermeden ÖNCE başlıyoruz: televizyon hızlı cevap
    // verdiğinde araya giren mikrosaniyede cevabı kaçırmamak için.
    final future = _messages.stream.firstWhere(accept);
    _send(destination, namespace, {...payload, 'requestId': _requestId++});
    try {
      return await future.timeout(timeout ?? _stepTimeout);
    } on TimeoutException {
      throw CastException(onTimeout);
    } on StateError {
      // Akış cevap gelmeden kapandı: bağlantı düştü.
      throw const CastException('Televizyonla bağlantı kesildi.');
    }
  }

  void _send(String destination, String namespace, Map<String, Object?> body) {
    try {
      _socket.add(
        encodeCastMessage(
          sourceId: _sourceId,
          destinationId: destination,
          namespace: namespace,
          payload: jsonEncode(body),
        ),
      );
    } catch (e) {
      // Kapanmış sokete yazmak istisna atıyor; çağıranı bununla meşgul
      // etmenin anlamı yok, zaman aşımı zaten devreye girecek.
      debugPrint('youtube-cast: komut gönderilemedi: $e');
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
    if (!_messages.isClosed) await _messages.close();
    _socket.destroy();
  }
}
