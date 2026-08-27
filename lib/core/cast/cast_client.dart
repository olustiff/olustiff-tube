import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cast_protocol.dart';

/// Televizyondaki alıcıya komut gönderen istemci.
///
/// Bütün istekler kısa zaman aşımlı: televizyon kapandığında ya da ağ
/// koptuğunda arayüz saniyelerce donmamalı, hemen "ulaşılamıyor" demeli.
class CastClient {
  CastClient(this.device, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final CastDevice device;
  final http.Client _http;

  static const _timeout = Duration(seconds: 4);

  /// Videoyu televizyonda açar.
  ///
  /// [position] telefonda kaldığı yer: kullanıcı yarısına kadar izlediği bir
  /// videoyu televizyona attığında baştan başlaması hata gibi duruyor.
  Future<void> play({
    required String videoId,
    required String title,
    String? artist,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) =>
      _post('/cast', {
        'videoId': videoId,
        'title': title,
        'artist': artist,
        'thumbnailUrl': thumbnailUrl,
        'positionMs': position.inMilliseconds,
      });

  /// Uzaktan kumanda komutu gönderir.
  ///
  /// [volume] yalnızca mutlak ses komutunda anlamlı (0..1).
  Future<void> command(String action, {Duration? position, double? volume}) {
    if (!CastCommand.all.contains(action)) {
      throw CastException('Bilinmeyen komut: $action');
    }
    return _post('/command', {
      'action': action,
      if (position != null) 'positionMs': position.inMilliseconds,
      if (volume != null) 'volume': volume.clamp(0.0, 1.0),
    });
  }

  /// Televizyonda ne çaldığını sorar. Ulaşılamıyorsa null döner —
  /// yoklama arayüzü hatayla dolduramaz.
  Future<CastRemoteState?> remoteState() async {
    try {
      final response =
          await _http.get(device.endpoint('/state')).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map) return null;
      return CastRemoteState.tryParse(body['state']);
    } catch (_) {
      return null;
    }
  }

  /// Cihaz hâlâ orada mı. Hatırlanan bir televizyona yeniden bağlanmadan
  /// önce sorulur.
  Future<bool> ping() async {
    try {
      final response =
          await _http.get(device.endpoint('/ping')).timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close();

  Future<void> _post(String path, Map<String, Object?> body) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            device.endpoint(path),
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: utf8.encode(jsonEncode(body)),
          )
          .timeout(_timeout);
    } catch (e) {
      // Ağ hatasının teknik metni kullanıcıya bir şey anlatmıyor; sebebi
      // anlatan tek bir cümleye çeviriyoruz.
      throw CastException(
        '${device.name} cihazına ulaşılamadı. '
        'Televizyon açık ve aynı Wi-Fi ağında olmalı.',
      );
    }
    if (response.statusCode != 200) {
      throw CastException(
        'Televizyon isteği kabul etmedi (${response.statusCode}).',
      );
    }
  }
}
