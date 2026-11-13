import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cast_protocol.dart' show CastException;
import 'youtube_cast_protocol.dart';
import '../i18n/lang.dart';

/// Televizyondaki YouTube'a komut gönderen Lounge oturumu.
///
/// Lounge, YouTube'un kendi telefon↔televizyon protokolü — ekrandaki "TV
/// kodu" eşleştirmesi de bunu kullanıyor. Resmî olarak BELGELENMİŞ DEĞİL.
///
/// Neden yine de bu yol: alıcıya oynatılacak videoyu bildirmenin başka yolu
/// yok. Cast'in standart `LOAD` komutu YouTube alıcısı tarafından
/// `INVALID_COMMAND` ile reddediliyor, DIAL ise test edilen Google TV'de
/// YouTube'u hiç kaydetmiyor (bkz. [youtube_cast_protocol]).
///
/// Belgelenmemiş olmanın bedeli kabul edilerek şu korumalar konuldu:
/// - Her adım sebebini söyleyen bir [CastException] ile başarısız oluyor;
///   sessiz "hiçbir şey olmadı" durumu yok.
/// - Arayüz yalnızca gerçekten çalıştığı doğrulanan kontrolleri gösteriyor.
class LoungeSessionClient {
  LoungeSessionClient._(
    this._http,
    this._session,
    this._deviceId,
    this._screenId,
    this._senderName,
  );

  final http.Client _http;

  /// Oturum kimlikleri. Düştüğünde yenisiyle DEĞİŞTİRİLİYOR (bkz.
  /// [_command]), bu yüzden sabit değil.
  LoungeSession _session;

  /// Bu telefonu tanımlayan rastgele kimlik; oturum boyunca sabit kalmalı.
  final String _deviceId;

  /// Oturumu yeniden kurabilmek için saklanıyor.
  final String _screenId;
  final String _senderName;

  static const _timeout = Duration(seconds: 10);
  static final _random = Random();

  static const _pairingUrl =
      'https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch';
  static const _bindUrl = 'https://www.youtube.com/api/lounge/bc/bind';

  /// `Origin` gerçek YouTube gönderenlerinin de yolladığı başlık.
  ///
  /// Uç noktalar şu an onsuz da cevap veriyor, ama bazı cihaz ve uçlar
  /// başlıksız isteği 403 ile reddediyor; alışılmış istemciden ayrışmamak
  /// bedava bir dayanıklılık.
  static const Map<String, String> _formHeaders = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'Origin': 'https://www.youtube.com',
  };

  /// Komut sırası. Sunucu artan `RID` bekliyor; tekrar eden numara istek
  /// sessizce yok sayılmasına yol açıyor.
  int _requestId = 2;

  /// Gönderilen komut sayısı (`ofs`).
  ///
  /// Sunucu bunu komutları sıraya dizmek için kullanıyor. Sabit bırakmak
  /// (hep 0) art arda gelen komutların TEKRAR sayılmasına ve sessizce
  /// yutulmasına yol açıyor — düğmeye ikinci kez basıldığında hiçbir şey
  /// olmamasının sebebi buydu.
  int _commandOffset = 0;

  /// Alınan son olayın sırası.
  int _lastEventIndex = 0;

  /// [screenId] için Lounge oturumu açar.
  static Future<LoungeSessionClient> open(
    String screenId, {
    http.Client? httpClient,
    String senderName = 'oLusTifF',
  }) async {
    final client = httpClient ?? http.Client();
    final deviceId = _randomId(32);

    final token = await _fetchToken(client, screenId);
    final session = await _bind(client, token, deviceId, senderName);
    return LoungeSessionClient._(
      client,
      session,
      deviceId,
      screenId,
      senderName,
    );
  }

  static Future<String> _fetchToken(http.Client client, String screenId) async {
    final http.Response response;
    try {
      response = await client
          .post(
            Uri.parse(_pairingUrl),
            headers: _formHeaders,
            body: {'screen_ids': screenId},
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('youtube-cast: Lounge belirteci alınamadı: $e');
      // Buraya kadarki her şey yerel ağdaydı; ilk internet adımı burası.
      throw CastException(tr(
        'YouTube ile bağlantı kurulamadı. Telefonun internet bağlantısını '
        'kontrol edin.',
        "Could not connect to YouTube. Check the phone's internet "
        'connection.',
      ));
    }

    if (response.statusCode != 200) {
      throw CastException(
        tr('YouTube eşleştirmeyi kabul etmedi (${response.statusCode}).',
            'YouTube rejected the pairing (${response.statusCode}).'),
      );
    }

    final token = parseLoungeToken(response.body, screenId: screenId);
    if (token == null) {
      throw CastException(tr('Televizyondaki YouTube ile eşleşilemedi.',
          'Could not pair with YouTube on the TV.'));
    }
    return token;
  }

  static Future<LoungeSession> _bind(
    http.Client client,
    String token,
    String deviceId,
    String senderName,
  ) async {
    final http.Response response;
    try {
      response = await client
          .post(
            Uri.parse(_bindUrl).replace(
              queryParameters: {
                ..._commonParameters(token, deviceId, senderName),
                'RID': '1',
                'zx': _randomId(12),
              },
            ),
            headers: _formHeaders,
            // `count=0`: bu istek komut taşımıyor, yalnızca oturum açıyor.
            body: {'count': '0'},
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('youtube-cast: Lounge oturumu açılamadı: $e');
      throw CastException(tr('Televizyondaki YouTube ile bağlantı kurulamadı.',
          'Could not connect to YouTube on the TV.'));
    }

    if (response.statusCode != 200) {
      throw CastException(
        tr(
          'Televizyondaki YouTube bağlantıyı kabul etmedi '
          '(${response.statusCode}).',
          'YouTube on the TV rejected the connection '
          '(${response.statusCode}).',
        ),
      );
    }

    final events = parseLoungeEvents(response.bodyBytes);
    final session = extractLoungeSession(events, loungeToken: token);
    if (session == null) {
      throw CastException(tr('Televizyondaki YouTube oturumu kurulamadı.',
          'Could not set up the YouTube session on the TV.'));
    }
    return session;
  }

  /// Videoyu televizyonda açar.
  ///
  /// [position] telefonda kalınan yer: yarısına kadar izlenen bir videonun
  /// televizyonda baştan başlaması hata gibi duruyor.
  Future<void> playVideo(String videoId, {Duration position = Duration.zero}) =>
      _command(LoungeCommand.setPlaylist, {
        'videoId': videoId,
        'currentTime': (position.inMilliseconds / 1000).toStringAsFixed(3),
        'currentIndex': '0',
        'listId': '',
        'audioOnly': 'false',
      });

  Future<void> play() => _command(LoungeCommand.play);

  Future<void> pause() => _command(LoungeCommand.pause);

  Future<void> seekTo(Duration position) => _command(LoungeCommand.seekTo, {
        'newTime': (position.inMilliseconds / 1000).toStringAsFixed(3),
      });

  Future<void> next() => _command(LoungeCommand.next);

  Future<void> previous() => _command(LoungeCommand.previous);

  /// Televizyondaki oynatmayı durdurur.
  Future<void> stopVideo() => _command(LoungeCommand.stop);

  /// Komutu gönderir; oturum düşmüşse BİR KEZ yeniden kurup tekrar dener.
  ///
  /// Yeniden deneme süs değil, bu protokolün bilinen bir davranışı: oturum
  /// bir süre boşta kaldıktan sonra (televizyon ekran koruyucuya geçtiğinde
  /// ya da yaklaşık yarım dakika komut gitmediğinde) sunucu `Unknown SID` /
  /// `410 Gone` dönmeye başlıyor. Bu, kullanıcının bir şeyi yanlış yaptığı
  /// anlamına gelmiyor; sessizce yeniden bağlanıp komutu iletmek doğru
  /// davranış. Tek sefer deneniyor — televizyon gerçekten gittiyse ikinci
  /// deneme yalnızca hatayı geciktirir.
  Future<void> _command(
    String command, [
    Map<String, String>? parameters,
  ]) async {
    try {
      await _postCommand(command, parameters);
    } on _LoungeSessionLost {
      debugPrint('youtube-cast: oturum düştü, yeniden kuruluyor');
      await _rebind();
      try {
        await _postCommand(command, parameters);
      } on _LoungeSessionLost {
        throw CastException(tr(
          'Televizyonla bağlantı düştü. Videoyu yeniden gönderin.',
          'The connection to the TV dropped. Send the video again.',
        ));
      }
    }
  }

  Future<void> _rebind() async {
    final token = await _fetchToken(_http, _screenId);
    _session = await _bind(_http, token, _deviceId, _senderName);
    _requestId = 2;
    _commandOffset = 0;
    _lastEventIndex = 0;
  }

  Future<void> _postCommand(
    String command,
    Map<String, String>? parameters,
  ) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(_bindUrl).replace(
              queryParameters: {
                ..._commonParameters(
                  _session.loungeToken,
                  _deviceId,
                  _senderName,
                ),
                'SID': _session.sessionId,
                'gsessionid': _session.gSessionId,
                'AID': '$_lastEventIndex',
                'RID': '${_requestId++}',
                'zx': _randomId(12),
              },
            ),
            headers: _formHeaders,
            body: {
              'count': '1',
              'ofs': '${_commandOffset++}',
              'req0__sc': command,
              if (parameters != null)
                for (final entry in parameters.entries)
                  'req0_${entry.key}': entry.value,
            },
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('youtube-cast: $command gönderilemedi: $e');
      throw CastException(tr('Televizyona komut gönderilemedi.',
          'Could not send the command to the TV.'));
    }

    if (isLoungeSessionLost(response.statusCode, response.body)) {
      throw const _LoungeSessionLost();
    }
    if (response.statusCode != 200) {
      throw CastException(tr(
          'Televizyon komutu kabul etmedi '
          '(${response.statusCode}).',
          'The TV rejected the command (${response.statusCode}).'));
    }

    final events = parseLoungeEvents(response.bodyBytes);
    final last = lastLoungeEventIndex(events);
    if (last > _lastEventIndex) _lastEventIndex = last;
  }

  static Map<String, String> _commonParameters(
    String token,
    String deviceId,
    String senderName,
  ) =>
      {
        // `REMOTE_CONTROL`: bu uç kumanda, ekran değil.
        'device': 'REMOTE_CONTROL',
        'id': deviceId,
        'name': senderName,
        'app': 'youtube-desktop',
        'mdx-version': '3',
        'loungeIdToken': token,
        'VER': '8',
        'v': '2',
        'CVER': '1',
        't': '1',
      };

  static String _randomId(int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      length,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  void close() => _http.close();
}

/// Oturumun düştüğünü bildiren iç işaret.
///
/// [CastException] DEĞİL, çünkü kullanıcıya gösterilecek bir hata değil:
/// yakalanıp yeniden bağlanmayı tetikliyor ve kullanıcı hiçbir şey fark
/// etmiyor.
class _LoungeSessionLost implements Exception {
  const _LoungeSessionLost();
}
