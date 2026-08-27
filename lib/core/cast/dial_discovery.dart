import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'youtube_cast_protocol.dart';

/// Ağdaki, kendi YouTube uygulaması olan televizyonları bulur (SSDP/DIAL).
///
/// Keşif İKİ aşamalı — [CastDiscovery] ile aynı sebepten:
///
/// 1. **Çok noktaya yayın (multicast)** — SSDP'nin standart yolu.
/// 2. **Tarama (unicast)** — cevapsız kalırsa ağdaki her adrese tek tek.
///
/// İkinci aşama şart: test edilen ev ağında SSDP çok noktaya yayını
/// TAMAMEN engellenmiş durumda (239.255.255.250'ye giden paket hiç cevap
/// almıyor), ama aynı televizyona 1900 portundan doğrudan sorulduğunda
/// eksiksiz cevap veriyor. Yalnızca çok noktaya yayına güvenen bir keşif bu
/// ağda hiçbir cihaz bulamıyordu.
///
/// Not: [CastDiscovery] ile benzer adres hesabı yapılıyor ama kod paylaşımı
/// yok — o dosyadaki yardımcılar `@visibleForTesting` ve kendi protokolüne
/// bağlı; üretim kodundan onlara dayanmak iki protokolü birbirine kilitlerdi.
class DialDiscovery {
  const DialDiscovery();

  /// Çok noktaya yayın cevapsız kalırsa taramaya geçmeden önce beklenen süre.
  static const _sweepDelay = Duration(milliseconds: 700);

  /// Cihaz tanıtım belgesi ve port yoklaması için üst sınır.
  static const _probeTimeout = Duration(seconds: 3);

  /// Ağı tarar ve televizyonun kendi YouTube'una gönderim yapılabilen
  /// cihazları döner.
  ///
  /// Hata FIRLATMAZ: ağ kapalıysa ya da paketler engelliyse boş liste döner.
  Future<List<YouTubeCastDevice>> discover({
    Duration timeout = const Duration(milliseconds: 2800),
    http.Client? httpClient,
  }) async {
    RawDatagramSocket? socket;
    final responses = <String, SsdpResponse>{};

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final parsed = parseSsdpResponse(
          String.fromCharCodes(datagram.data),
        );
        // Aynı cihaz birkaç hizmet için ayrı cevap gönderiyor; kimliğe göre
        // teklenir.
        if (parsed != null) responses[parsed.deviceId] = parsed;
      }, onError: (Object _) {});

      final probe = encodeSsdpSearch().codeUnits;
      final addresses = await _localAddresses();

      _sendAll(socket, probe, [InternetAddress('239.255.255.250')]);
      await Future<void>.delayed(_sweepDelay);

      // Çok noktaya yayın işe yaradıysa 254 paket göndermeye gerek yok.
      if (responses.isEmpty) {
        _sendAll(socket, probe, _sweepTargets(addresses));
      }

      final remaining = timeout - _sweepDelay;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    } on SocketException catch (e) {
      debugPrint('youtube-cast: keşif soketi açılamadı: $e');
    } finally {
      socket?.close();
    }

    final client = httpClient ?? http.Client();
    try {
      // Cihazlar paralel yoklanıyor: sırayla sorulsa üç televizyonlu bir evde
      // keşif üç kat uzardı.
      final devices = await Future.wait(
        responses.values.map((r) => _describe(r, client)),
      );
      return devices.whereType<YouTubeCastDevice>().toList(growable: false);
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// Cihazın adını okur ve Cast'e gerçekten açık olduğunu doğrular.
  ///
  /// Cast portu KAPALIYSA cihaz listelenmiyor. Sebep: DIAL'e cevap veren her
  /// cihaz YouTube açamıyor (yazıcılar, medya sunucuları da SSDP konuşuyor);
  /// listede görünüp dokunulduğunda hata veren bir satır, hiç görünmemekten
  /// kötü.
  Future<YouTubeCastDevice?> _describe(
    SsdpResponse response,
    http.Client client,
  ) async {
    final location = Uri.tryParse(response.location);
    if (location == null || location.host.isEmpty) return null;

    if (!await _castPortOpen(location.host)) {
      debugPrint('youtube-cast: ${location.host} Cast portunu açmıyor');
      return null;
    }

    String? name;
    try {
      final description = await client.get(location).timeout(_probeTimeout);
      if (description.statusCode == 200) {
        name = parseFriendlyName(description.body);
      }
    } catch (e) {
      // Ad okunamadı; cihaz yine de kullanılabilir, adres gösterilir.
      debugPrint('youtube-cast: ${location.host} adı okunamadı: $e');
    }

    return YouTubeCastDevice(
      id: response.deviceId,
      name: name ?? location.host,
      host: location.host,
    );
  }

  Future<bool> _castPortOpen(String host) async {
    try {
      final socket = await Socket.connect(host, castV2Port, timeout: _probeTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _sendAll(
    RawDatagramSocket socket,
    List<int> probe,
    List<InternetAddress> targets,
  ) {
    for (final target in targets) {
      try {
        socket.send(probe, target, 1900);
      } catch (e) {
        // Bazı arayüzlere (VPN, sanal köprü) paket gönderilemiyor; diğerleri
        // denenmeye devam etmeli.
        debugPrint('youtube-cast: $target adresine sorulamadı: $e');
      }
    }
  }

  Future<List<String>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return interfaces
          .where((i) => isLocalNetworkInterface(i.name))
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .toList(growable: false);
    } catch (e) {
      debugPrint('youtube-cast: ağ arayüzleri okunamadı: $e');
      return const [];
    }
  }

  /// Bu arayüz üzerinden televizyon aranır mı.
  ///
  /// Mobil veri ve tünel (VPN) arayüzleri eleniyor: operatörün taşıyıcı ağına
  /// 254 yoklama paketi göndermenin karşılığı yok, orada televizyon olamaz.
  @visibleForTesting
  static bool isLocalNetworkInterface(String name) {
    const mobileOrTunnel = ['rmnet', 'ccmni', 'pdp', 'tun', 'ppp', 'clat'];
    final lower = name.toLowerCase();
    return !mobileOrTunnel.any(lower.startsWith);
  }

  /// Çok noktaya yayın engellendiğinde tek tek sorulacak adresler.
  ///
  /// /24 varsayımı bilinçli: `NetworkInterface` ağ maskesini vermiyor ve ev
  /// ağlarının neredeyse tamamı /24.
  @visibleForTesting
  static List<InternetAddress> computeSweepTargets(Iterable<String> addresses) =>
      _sweepTargets(addresses);

  static List<InternetAddress> _sweepTargets(Iterable<String> addresses) {
    final targets = <String>{};
    for (final address in addresses) {
      final parts = address.split('.');
      if (parts.length != 4) continue;
      if (parts.first == '127') continue;
      if (parts.any((p) => int.tryParse(p) == null)) continue;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      for (var host = 1; host < 255; host++) {
        targets.add('$prefix.$host');
      }
    }
    return targets.map(InternetAddress.new).toList(growable: false);
  }
}
