import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cast_protocol.dart' show CastException;
import 'youtube_cast_protocol.dart';

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
  LoungeSessionClient._(this._http, this._session, this._deviceId);

  final http.Client _http;
  final LoungeSession _session;

  /// Bu telefonu tanımlayan rastgele kimlik; oturum boyunca sabit kalmalı.
  final String _deviceId;

  static const _timeout = Duration(seconds: 10);
  static final _random = Random();

  static const _pairingUrl =
      'https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch';
  static const _bindUrl = 'https://www.youtube.com/api/lounge/bc/bind';

  /// Komut sırası. Sunucu artan `RID` bekliyor; tekrar eden numara istek
  /// sessizce yok sayılmasına yol açıyor.
  int _requestId = 2;

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
    return LoungeSessionClient._(client, session, deviceId);
  }

  static Future<String> _fetchToken(http.Client client, String screenId) async {
    final http.Response response;
    try {
      response = await client
          .post(
            Uri.parse(_pairingUrl),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {'screen_ids': screenId},
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('youtube-cast: Lounge belirteci alınamadı: $e');
      // Buraya kadarki her şey yerel ağdaydı; ilk internet adımı burası.
      throw const CastException(
        'YouTube ile bağlantı kurulamadı. Telefonun internet bağlantısını '
        'kontrol edin.',
      );
    }

    if (response.statusCode != 200) {
      throw CastException(
        'YouTube eşleştirmeyi kabul etmedi (${response.statusCode}).',
      );
    }

    final token = parseLoungeToken(response.body, screenId: screenId);
    if (token == null) {
      throw const CastException('Televizyondaki YouTube ile eşleşilemedi.');
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
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            // `count=0`: bu istek komut taşımıyor, yalnızca oturum açıyor.
            body: {'count': '0'},
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('youtube-cast: Lounge oturumu açılamadı: $e');
      throw const CastException('Televizyondaki YouTube ile bağlantı kurulamadı.');
    }

    if (response.statusCode != 200) {
      throw CastException(
        'Televizyondaki YouTube bağlantıyı kabul etmedi '
        '(${response.statusCode}).',
      );
    }

    final events = parseLoungeEvents(response.bodyBytes);
    final session = extractLoungeSession(events, loungeToken: token);
    if (session == null) {
      throw const CastException('Televizyondaki YouTube oturumu kurulamadı.');
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

  Future<void> _command(String command, [Map<String, String>? parameters]) async {
    final rid = _requestId++;
    final http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(_bindUrl).replace(
              queryParameters: {
                ..._commonParameters(
                  _session.loungeToken,
                  _deviceId,
                  'oLusTifF',
                ),
                'SID': _session.sessionId,
                'gsessionid': _session.gSessionId,
                'AID': '$_lastEventIndex',
                'RID': '$rid',
                'zx': _randomId(12),
              },
            ),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {
              'count': '1',
              'ofs': '0',
              'req0__sc': command,
              if (parameters != null)
                for (final entry in parameters.entries)
                  'req0_${entry.key}': entry.value,
            },
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('youtube-cast: $command gönderilemedi: $e');
      throw const CastException('Televizyona komut gönderilemedi.');
    }

    // 400/401: oturum düşmüş ya da belirteç geçersiz olmuş. Kullanıcı için
    // ikisi de "yeniden bağlanmak gerekiyor" demek.
    if (response.statusCode == 400 || response.statusCode == 401) {
      throw const CastException(
        'Televizyonla bağlantı düştü. Yeniden göndermeyi deneyin.',
      );
    }
    if (response.statusCode != 200) {
      throw CastException('Televizyon komutu kabul etmedi '
          '(${response.statusCode}).');
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
