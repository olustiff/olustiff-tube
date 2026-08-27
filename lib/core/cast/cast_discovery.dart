import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'cast_protocol.dart';

/// Yerel ağdaki televizyonları bulur.
///
/// Keşif İKİ aşamalı, çünkü tek bir yöntem her ağda çalışmıyor:
///
/// 1. **Yayın (broadcast)** — tek pakette bütün ağa sorar, en ucuzu.
/// 2. **Tarama (unicast)** — yayın paketi cevapsız kalırsa ağdaki her adrese
///    tek tek sorar.
///
/// İkinci aşama gerçek bir ihtiyaçtan doğdu: test edilen ev ağında iki cihaz
/// birbiriyle doğrudan (unicast) konuşabiliyor ama modem yayın paketlerini
/// iletmiyor — yalnızca yayına güvenen keşif televizyonu HİÇ bulamıyordu.
/// 254 küçük paket göndermek 5 milisaniye sürüyor ve cevap ~150 ms'de
/// geliyor; kullanıcı farkı hissetmiyor.
///
/// Neden mDNS/NSD değil: mDNS çok noktaya yayın kullanıyor ve yayını
/// engelleyen ağlar çoğu zaman onu da engelliyor; üstüne Android'in NSD
/// servisi bazı TV kutularında hiç cevap vermiyor.
class CastDiscovery {
  const CastDiscovery();

  /// Yayın paketi cevapsız kalırsa taramaya geçmeden önce beklenen süre.
  static const _sweepDelay = Duration(milliseconds: 600);

  /// Ağı tarar ve bulunan televizyonları döner.
  ///
  /// Hata FIRLATMAZ: ağ kapalıysa ya da paketler engelliyse boş liste döner.
  /// "Bulunamadı" ile "hata" kullanıcı için aynı şey — arayüz tek bir
  /// açıklayıcı mesaj gösteriyor.
  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    RawDatagramSocket? socket;
    final found = <String, CastDevice>{};
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        final device = parseDeviceAnnouncement(
          decodePayload(datagram.data),
          datagram.address.address,
        );
        // Aynı televizyon birden çok adrese cevap verebilir; kimliğe göre
        // teklenir.
        if (device != null) found[device.id] = device;
      }, onError: (Object _) {});

      final probe = encodeDiscoveryProbe().codeUnits;
      final addresses = await _localAddresses();

      _sendAll(socket, probe, computeBroadcastTargets(addresses));
      await Future<void>.delayed(_sweepDelay);

      // Yayın işe yaradıysa ağı taramaya gerek yok.
      if (found.isEmpty) {
        _sendAll(socket, probe, computeSweepTargets(addresses));
      }

      // Erken çıkış YOK: birden fazla televizyon olabilir, ilkini görünce
      // durmak diğerlerini gizlerdi.
      final remaining = timeout - _sweepDelay;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    } on SocketException catch (e) {
      debugPrint('cast: keşif soketi açılamadı: $e');
    } finally {
      socket?.close();
    }
    return found.values.toList(growable: false);
  }

  void _sendAll(
    RawDatagramSocket socket,
    List<int> probe,
    List<InternetAddress> targets,
  ) {
    for (final target in targets) {
      try {
        socket.send(probe, target, castDiscoveryPort);
      } catch (e) {
        // Bazı arayüzlere (VPN, sanal köprü) paket gönderilemiyor;
        // diğerleri denenmeye devam etmeli.
        debugPrint('cast: $target adresine keşif gönderilemedi: $e');
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
      debugPrint('cast: ağ arayüzleri okunamadı: $e');
      return const [];
    }
  }

  /// Keşif paketinin gönderileceği yayın adresleri.
  ///
  /// 255.255.255.255 tek başına yetmiyor: Android bu "sınırlı yayın" adresini
  /// bazı sürümlerde hiç göndermiyor. Bu yüzden her yerel adres için o ağın
  /// kendi yayın adresi de (ör. 192.168.1.255) hesaplanıyor.
  ///
  /// /24 varsayımı bilinçli: `NetworkInterface` ağ maskesini vermiyor ve ev
  /// ağlarının neredeyse tamamı /24. Maske daha genişse yalnızca keşfin
  /// erişimi daralır, yanlış bir cihaza paket gitmez.
  @visibleForTesting
  static List<InternetAddress> computeBroadcastTargets(
    Iterable<String> addresses,
  ) {
    final targets = <String>{'255.255.255.255'};
    for (final prefix in _subnets(addresses)) {
      targets.add('$prefix.255');
    }
    return targets.map(InternetAddress.new).toList(growable: false);
  }

  /// Ağdaki her adres: yayın engellendiğinde tek tek sorulacak hedefler.
  ///
  /// Kendi adresimiz de listede kalıyor — televizyonda çalışan uygulama
  /// kendi kendini bulmuyor zaten (paketi kendine göndermek zararsız), ama
  /// bir cihazda iki arayüz varsa (Wi-Fi + Ethernet) diğerini atlamamak
  /// gerekiyor.
  @visibleForTesting
  static List<InternetAddress> computeSweepTargets(Iterable<String> addresses) {
    final targets = <String>{};
    for (final prefix in _subnets(addresses)) {
      for (var host = 1; host < 255; host++) {
        targets.add('$prefix.$host');
      }
    }
    return targets.map(InternetAddress.new).toList(growable: false);
  }

  /// Bu arayüz üzerinden televizyon aranır mı.
  ///
  /// Mobil veri arayüzleri (rmnet/ccmni/pdp) ELENİYOR: telefon aynı anda hem
  /// Wi-Fi'da hem mobil veride olabiliyor ve operatörün taşıyıcı ağına 254
  /// yoklama paketi göndermenin hiçbir karşılığı yok — orada televizyon
  /// olamaz. Tünel arayüzleri de (VPN) aynı sebeple eleniyor.
  @visibleForTesting
  static bool isLocalNetworkInterface(String name) {
    const mobileOrTunnel = ['rmnet', 'ccmni', 'pdp', 'tun', 'ppp', 'clat'];
    final lower = name.toLowerCase();
    return !mobileOrTunnel.any(lower.startsWith);
  }

  /// Gelen paketi metne çevirir.
  ///
  /// UTF-8 ŞART: cihaz adları Türkçe karakter içeriyor ("Oturma Odası TV'si")
  /// ve baytları doğrudan karakter saymak (`String.fromCharCodes`) adı
  /// "Oturma OdasÄ± TV'si"ye çeviriyordu.
  ///
  /// [allowMalformed]: ağda dolaşan her paket bizim değil; bozuk bir bayt
  /// dizisi istisna fırlatıp keşfi kesmemeli — o paket zaten sonraki adımda
  /// elenir.
  @visibleForTesting
  static String decodePayload(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  /// Yerel adreslerden /24 ağ öneklerini (ör. `192.168.1`) çıkarır.
  static Set<String> _subnets(Iterable<String> addresses) {
    final subnets = <String>{};
    for (final address in addresses) {
      final parts = address.split('.');
      if (parts.length != 4) continue;
      // Geri döngü ve rakam olmayan parçalar ağ değil.
      if (parts.first == '127') continue;
      if (parts.any((p) => int.tryParse(p) == null)) continue;
      subnets.add('${parts[0]}.${parts[1]}.${parts[2]}');
    }
    return subnets;
  }
}
