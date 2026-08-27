import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/core/cast/dial_discovery.dart';
import 'package:olustiff/core/cast/youtube_cast_protocol.dart';

/// Gerçek bir Google TV kutusunun verdiği SSDP cevabı (kısaltılmadı).
const _ssdpResponse = 'HTTP/1.1 200 OK\r\n'
    'CACHE-CONTROL: max-age=1800\r\n'
    'LOCATION: http://192.168.0.108:8008/ssdp/device-desc.xml\r\n'
    'SERVER: Linux/5.15, UPnP/1.0, Chromecast/1.6.18\r\n'
    'ST: urn:dial-multiscreen-org:service:dial:1\r\n'
    'USN: uuid:db6b54db-45c1-3ff4-6154-676f62951966::'
    'urn:dial-multiscreen-org:service:dial:1\r\n'
    '\r\n';

void main() {
  group('SSDP cevabı', () {
    test('adres ve kimlik okunur', () {
      final parsed = parseSsdpResponse(_ssdpResponse);
      expect(parsed, isNotNull);
      expect(parsed!.location, 'http://192.168.0.108:8008/ssdp/device-desc.xml');
    });

    test('kimlikten hizmet son eki atılır', () {
      // Aynı televizyon farklı hizmetler için farklı USN gönderiyor; son ek
      // atılmazsa aynı cihaz listede birkaç kez görünür.
      final dial = parseSsdpResponse(_ssdpResponse)!;
      final root = parseSsdpResponse(
        _ssdpResponse.replaceAll(
          '::urn:dial-multiscreen-org:service:dial:1',
          '::upnp:rootdevice',
        ),
      )!;
      expect(dial.deviceId, 'uuid:db6b54db-45c1-3ff4-6154-676f62951966');
      expect(root.deviceId, dial.deviceId);
    });

    test('başlıklar büyük/küçük harfe duyarsız okunur', () {
      final parsed = parseSsdpResponse(
        _ssdpResponse.replaceAll('LOCATION:', 'Location:'),
      );
      expect(parsed?.location, contains('192.168.0.108'));
    });

    test('adresi olmayan cevap kabul edilmez', () {
      final withoutLocation = _ssdpResponse
          .split('\r\n')
          .where((l) => !l.startsWith('LOCATION'))
          .join('\r\n');
      expect(parseSsdpResponse(withoutLocation), isNull);
    });

    test('bize ait olmayan paketler cevap sayılmaz', () {
      // Ağda dolaşan her paket SSDP değil; hata değil, "ilgilendirmiyor".
      expect(parseSsdpResponse('düz metin'), isNull);
      expect(parseSsdpResponse(''), isNull);
      expect(parseSsdpResponse('HTTP/1.1 404 Not Found\r\n\r\n'), isNull);
    });

    test('arama paketi çok noktaya yayın adresini taşır', () {
      // Tek bir cihaza gönderilse bile HOST bu değeri taşımalı; bazı
      // cihazlar farklı yazıldığında hiç cevap vermiyor.
      expect(encodeSsdpSearch(), contains('HOST: 239.255.255.250:1900'));
      expect(encodeSsdpSearch(), contains(dialSearchTarget));
    });
  });

  group('cihaz tanıtım belgesi', () {
    test('cihaz adı okunur', () {
      expect(
        parseFriendlyName('<root><friendlyName>Salon TV</friendlyName></root>'),
        'Salon TV',
      );
    });

    test('XML kaçışları çözülür', () {
      // Gerçek cihazda karşılaşıldı: kesme işareti &#39; olarak geliyor ve
      // ham hâliyle gösterilince kullanıcı adını tanıyamıyor.
      expect(
        parseFriendlyName(
          '<friendlyName>Oturma Odası TV&#39;si</friendlyName>',
        ),
        "Oturma Odası TV'si",
      );
      expect(
        parseFriendlyName('<friendlyName>Ali &amp; Veli</friendlyName>'),
        'Ali & Veli',
      );
    });

    test('ad yoksa null döner', () {
      // Cihaz yine kullanılabilir; arayüz adres gösteriyor.
      expect(parseFriendlyName('<root></root>'), isNull);
      expect(parseFriendlyName('<friendlyName>  </friendlyName>'), isNull);
    });
  });

  group('Cast v2 çerçeveleme', () {
    List<int> frame(String namespace, String payload) => encodeCastMessage(
          sourceId: 'sender-0',
          destinationId: 'receiver-0',
          namespace: namespace,
          payload: payload,
        );

    test('kodlanan mesaj geri çözülür', () {
      final messages = CastFrameReader().add(
        frame(CastNamespace.receiver, '{"type":"PING"}'),
      );
      expect(messages, hasLength(1));
      expect(messages.single.namespace, CastNamespace.receiver);
      expect(messages.single.json?['type'], 'PING');
    });

    test('parçalara bölünmüş mesaj birleştirilir', () {
      // TLS soketi mesaj sınırlarını korumuyor: tek bir okuma yarım mesaj
      // getirebilir. Bu birleştirme olmadan protokol rastgele bozuluyordu.
      final bytes = frame(CastNamespace.youtubeMdx, '{"type":"a"}');
      final reader = CastFrameReader();
      for (var i = 0; i < bytes.length - 1; i++) {
        expect(reader.add([bytes[i]]), isEmpty);
      }
      final messages = reader.add([bytes.last]);
      expect(messages, hasLength(1));
      expect(messages.single.namespace, CastNamespace.youtubeMdx);
    });

    test('tek okumada gelen birden çok mesaj ayrılır', () {
      final messages = CastFrameReader().add([
        ...frame(CastNamespace.heartbeat, '{"type":"PING"}'),
        ...frame(CastNamespace.receiver, '{"type":"RECEIVER_STATUS"}'),
      ]);
      expect(messages, hasLength(2));
      expect(messages.first.namespace, CastNamespace.heartbeat);
      expect(messages.last.json?['type'], 'RECEIVER_STATUS');
    });

    test('Türkçe karakterli yük bozulmadan taşınır', () {
      final messages = CastFrameReader().add(
        frame(CastNamespace.receiver, '{"name":"Oturma Odası"}'),
      );
      expect(messages.single.json?['name'], 'Oturma Odası');
    });

    test('bozuk uzunluk sonsuz tampon büyümesine yol açmaz', () {
      // Akış senkronu kaybolduysa tamponu atmak, sınırsız büyümekten iyi.
      final messages = CastFrameReader().add([0x7f, 0xff, 0xff, 0xff, 0x01]);
      expect(messages, isEmpty);
    });
  });

  group('Lounge cevabı', () {
    List<int> chunk(String json) => [
          ...utf8.encode('${utf8.encode(json).length}\n'),
          ...utf8.encode(json),
        ];

    test('oturum kimlikleri çıkarılır', () {
      final events = parseLoungeEvents(
        chunk('[[0,["c","SID123","",8]],[1,["S","GS456"]]]'),
      );
      final session = extractLoungeSession(events, loungeToken: 'T');
      expect(session, isNotNull);
      expect(session!.sessionId, 'SID123');
      expect(session.gSessionId, 'GS456');
    });

    test('gsessionid eksikse oturum kurulmamış sayılır', () {
      // Yarım kimlikle komut göndermek sessizce başarısız olurdu.
      final events = parseLoungeEvents(chunk('[[0,["c","SID123","",8]]]'));
      expect(extractLoungeSession(events, loungeToken: 'T'), isNull);
    });

    test('uzunluk BAYT cinsinden okunur', () {
      // Bu testin sebebi somut: cihaz adları Türkçe karakter içerdiğinde
      // metin uzunluğu bayt uzunluğundan küçük kalıyor ve metin üzerinden
      // yapılan çerçeveleme kayıyordu.
      const json = '[[0,["c","SID","",8]],[1,["S","GS"]],'
          '[2,["ad",{"n":"Oturma Odası TV\'si"}]]]';
      expect(utf8.encode(json).length, greaterThan(json.length));
      final events = parseLoungeEvents(chunk(json));
      expect(extractLoungeSession(events, loungeToken: 'T')?.sessionId, 'SID');
      expect(events.last.name, 'ad');
    });

    test('art arda gelen parçalar okunur', () {
      final events = parseLoungeEvents([
        ...chunk('[[0,["c","SID","",8]]]'),
        ...chunk('[[1,["S","GS"]]]'),
      ]);
      expect(events.map((e) => e.name), ['c', 'S']);
      expect(lastLoungeEventIndex(events), 1);
    });

    test('yarım kalan cevapta o ana kadarki olaylar korunur', () {
      // Elde olanla devam etmek, her şeyi atmaktan iyi.
      final events = parseLoungeEvents([
        ...chunk('[[0,["c","SID","",8]]]'),
        ...utf8.encode('999\n[[1,["S"'),
      ]);
      expect(events, hasLength(1));
      expect(events.single.name, 'c');
    });

    test('bozuk parça diğerlerini götürmez', () {
      final events = parseLoungeEvents([
        ...chunk('bu json değil'),
        ...chunk('[[7,["S","GS"]]]'),
      ]);
      expect(events, hasLength(1));
      expect(events.single.index, 7);
    });

    test('olay sırası en büyük numaradan alınır', () {
      final events = parseLoungeEvents(chunk('[[3,["a"]],[9,["b"]],[5,["c"]]]'));
      expect(lastLoungeEventIndex(events), 9);
    });
  });

  group('Lounge belirteci', () {
    test('eşleşen ekranın belirteci alınır', () {
      const body = '{"screens":[{"screenId":"S1","loungeToken":"TOK1"},'
          '{"screenId":"S2","loungeToken":"TOK2"}]}';
      expect(parseLoungeToken(body, screenId: 'S2'), 'TOK2');
    });

    test('eşleşme yoksa null döner', () {
      const body = '{"screens":[{"screenId":"S1","loungeToken":"TOK1"}]}';
      expect(parseLoungeToken(body, screenId: 'BAŞKA'), isNull);
    });

    test('bozuk cevap null döner', () {
      expect(parseLoungeToken('<html>hata</html>', screenId: 'S1'), isNull);
      expect(parseLoungeToken('{"screens":[]}', screenId: 'S1'), isNull);
    });
  });

  group('oturum kaybı ayrımı', () {
    test('410 kesin oturum kaybıdır', () {
      expect(isLoungeSessionLost(410, ''), isTrue);
    });

    test('bilinen oturum hataları yeniden bağlanmayı tetikler', () {
      // Televizyon ekran koruyucuya geçtiğinde bu geliyor; kullanıcıya hata
      // göstermek yerine sessizce yeniden bağlanmak doğru davranış.
      expect(isLoungeSessionLost(400, 'Unknown SID'), isTrue);
      expect(isLoungeSessionLost(401, 'Token Expired'), isTrue);
    });

    test('başka sebeple gelen 400 oturum kaybı sayılmaz', () {
      // Her 400'ü oturum kaybı saymak gerçek hataları sonsuz yeniden
      // bağlanma döngüsüne çevirirdi.
      expect(isLoungeSessionLost(400, 'Bad Request'), isFalse);
      expect(isLoungeSessionLost(200, 'Unknown SID'), isFalse);
      expect(isLoungeSessionLost(500, ''), isFalse);
    });
  });

  group('keşif hedefleri', () {
    test('mobil veri ve tünel arayüzleri elenir', () {
      // Operatörün taşıyıcı ağına 254 yoklama paketi göndermenin karşılığı
      // yok; orada televizyon olamaz.
      expect(DialDiscovery.isLocalNetworkInterface('wlan0'), isTrue);
      expect(DialDiscovery.isLocalNetworkInterface('eth0'), isTrue);
      expect(DialDiscovery.isLocalNetworkInterface('rmnet_data0'), isFalse);
      expect(DialDiscovery.isLocalNetworkInterface('tun0'), isFalse);
    });

    test('ağdaki her adres taranır, ağ ve yayın adresi hariç', () {
      final targets = DialDiscovery.computeSweepTargets(['192.168.0.106'])
          .map((a) => a.address)
          .toList();
      expect(targets, hasLength(254));
      expect(targets, contains('192.168.0.108'));
      expect(targets, isNot(contains('192.168.0.0')));
      expect(targets, isNot(contains('192.168.0.255')));
    });

    test('aynı adresteki iki DIAL sunucusu tek satır olur', () {
      // Gerçek cihazda görüldü: televizyon iki DIAL sunucusu çalıştırıyor ve
      // her biri farklı UPnP kimliğiyle cevap veriyor. Kimliğe göre teklemek
      // aynı televizyonu listede iki kez gösteriyordu.
      final deduped = DialDiscovery.dedupeByHost(const [
        YouTubeCastDevice(id: 'uuid:a', name: 'Salon', host: '192.168.0.108'),
        YouTubeCastDevice(id: 'uuid:b', name: 'Salon', host: '192.168.0.108'),
        YouTubeCastDevice(id: 'uuid:c', name: 'Yatak', host: '192.168.0.110'),
      ]);
      expect(deduped, hasLength(2));
      expect(deduped.map((d) => d.host), ['192.168.0.108', '192.168.0.110']);
    });

    test('adı okunabilen kayıt, adressiz olana tercih edilir', () {
      // İki DIAL sunucusundan yalnızca biri cihaz adını veriyor olabiliyor;
      // körlemesine ilkini almak listede ad yerine IP gösteriyordu.
      final deduped = DialDiscovery.dedupeByHost(const [
        YouTubeCastDevice(
          id: 'uuid:a',
          name: '192.168.0.108',
          host: '192.168.0.108',
        ),
        YouTubeCastDevice(
          id: 'uuid:b',
          name: "Oturma Odası TV'si",
          host: '192.168.0.108',
        ),
      ]);
      expect(deduped.single.name, "Oturma Odası TV'si");
    });

    test('geri döngü ve bozuk adresler taranmaz', () {
      expect(DialDiscovery.computeSweepTargets(['127.0.0.1']), isEmpty);
      expect(DialDiscovery.computeSweepTargets(['bozuk']), isEmpty);
    });
  });
}
