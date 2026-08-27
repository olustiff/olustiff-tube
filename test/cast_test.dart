import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:olustiff/core/cast/cast_client.dart';
import 'package:olustiff/core/cast/cast_controller.dart';
import 'package:olustiff/core/cast/cast_discovery.dart';
import 'package:olustiff/core/cast/cast_protocol.dart';

const _device = CastDevice(
  id: 'tv-1',
  name: 'Salon TV',
  host: '192.168.1.40',
  port: castControlPort,
);

void main() {
  // CastController yayın başlarken telefonu susturuyor; bu bir kanal
  // çağrısı olduğu için bağlama (binding) gerekiyor.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('keşif mesajları', () {
    test('telefonun sorduğu paketi televizyon tanır', () {
      expect(isDiscoveryProbe(encodeDiscoveryProbe()), isTrue);
    });

    test('bize ait olmayan paketler keşif sayılmaz', () {
      expect(isDiscoveryProbe('{"m":"başka-uygulama","t":"discover"}'), isFalse);
      expect(isDiscoveryProbe('düz metin'), isFalse);
      expect(isDiscoveryProbe(''), isFalse);
    });

    test('televizyonun cevabı çözülür ve adres gönderenden alınır', () {
      final raw = encodeDeviceAnnouncement(
        id: 'tv-1',
        name: 'Salon TV',
        appVersion: '1.7.2',
      );

      final device = parseDeviceAnnouncement(raw, '192.168.1.40');

      expect(device, isNotNull);
      expect(device!.id, 'tv-1');
      expect(device.name, 'Salon TV');
      // Televizyon kendi IP'sini bildirmiyor: paketin geldiği adres kullanılır.
      expect(device.host, '192.168.1.40');
      expect(device.port, castControlPort);
      expect(device.appVersion, '1.7.2');
    });

    test('farklı protokol sürümündeki cihaz listelenmez', () {
      final raw = jsonEncode({
        'm': castMagic,
        't': 'device',
        'v': castProtocolVersion + 1,
        'id': 'tv-1',
        'name': 'Salon TV',
        'port': castControlPort,
      });

      expect(parseDeviceAnnouncement(raw, '192.168.1.40'), isNull);
    });

    test('eksik ya da bozuk cevaplar sessizce elenir', () {
      String announcement(Map<String, Object?> overrides) => jsonEncode({
            'm': castMagic,
            't': 'device',
            'v': castProtocolVersion,
            'id': 'tv-1',
            'name': 'Salon TV',
            'port': castControlPort,
            ...overrides,
          });

      expect(parseDeviceAnnouncement('{bozuk', '1.2.3.4'), isNull);
      expect(parseDeviceAnnouncement(announcement({'m': 'x'}), '1.2.3.4'), isNull);
      expect(parseDeviceAnnouncement(announcement({'id': ''}), '1.2.3.4'), isNull);
      expect(parseDeviceAnnouncement(announcement({'name': 42}), '1.2.3.4'), isNull);
      expect(
        parseDeviceAnnouncement(announcement({'port': 0}), '1.2.3.4'),
        isNull,
      );
      expect(
        parseDeviceAnnouncement(announcement({'port': 70000}), '1.2.3.4'),
        isNull,
      );
    });

    test('aynı kimlikteki cihazlar tek sayılır', () {
      const a = CastDevice(id: 'tv-1', name: 'A', host: '10.0.0.1', port: 1);
      const b = CastDevice(id: 'tv-1', name: 'B', host: '10.0.0.2', port: 2);
      expect({a, b}, hasLength(1));
    });
  });

  group('yayın adresleri', () {
    test('her yerel ağ için kendi yayın adresi üretilir', () {
      final targets = CastDiscovery.computeBroadcastTargets([
        '192.168.1.34',
        '10.0.0.7',
      ]).map((a) => a.address);

      expect(targets, contains('192.168.1.255'));
      expect(targets, contains('10.0.0.255'));
      // Sınırlı yayın adresi her zaman denenir: bazı cihazlar yalnızca ona
      // cevap veriyor.
      expect(targets, contains('255.255.255.255'));
    });

    test('geri döngü ve geçersiz adresler atlanır', () {
      final targets = CastDiscovery.computeBroadcastTargets([
        '127.0.0.1',
        'fe80::1',
        'saçma',
      ]).map((a) => a.address);

      expect(targets, ['255.255.255.255']);
    });

    test('aynı ağdaki iki adres tek hedef üretir', () {
      final targets = CastDiscovery.computeBroadcastTargets([
        '192.168.1.34',
        '192.168.1.99',
      ]);

      expect(targets, hasLength(2)); // 192.168.1.255 + 255.255.255.255
    });
  });

  group('arayüz seçimi', () {
    test('Wi-Fi ve ethernet taranır', () {
      expect(CastDiscovery.isLocalNetworkInterface('wlan0'), isTrue);
      expect(CastDiscovery.isLocalNetworkInterface('eth0'), isTrue);
      expect(CastDiscovery.isLocalNetworkInterface('en0'), isTrue);
    });

    test('mobil veri ve VPN arayüzleri taranmaz', () {
      // Telefon aynı anda mobil veride olabiliyor; operatörün ağında
      // televizyon aramanın karşılığı yok.
      expect(CastDiscovery.isLocalNetworkInterface('rmnet_data7'), isFalse);
      expect(CastDiscovery.isLocalNetworkInterface('ccmni0'), isFalse);
      expect(CastDiscovery.isLocalNetworkInterface('tun0'), isFalse);
    });
  });

  group('paket çözme', () {
    test('Türkçe karakterli cihaz adı bozulmadan okunur', () {
      const name = "Oturma Odası TV'si";
      final bytes = utf8.encode(
        encodeDeviceAnnouncement(id: 'tv-1', name: name),
      );

      final device = parseDeviceAnnouncement(
        CastDiscovery.decodePayload(bytes),
        '192.168.0.108',
      );

      expect(device?.name, name);
    });

    test('bozuk baytlar istisna fırlatmaz', () {
      expect(
        () => CastDiscovery.decodePayload([0xFF, 0xFE, 0x00]),
        returnsNormally,
      );
    });
  });

  group('ağ taraması', () {
    // Yayın paketini iletmeyen ağlarda tek çare: her adrese tek tek sormak.
    test('ağdaki tüm konaklar hedeflenir', () {
      final targets = CastDiscovery.computeSweepTargets(['192.168.0.106'])
          .map((a) => a.address)
          .toList();

      expect(targets, hasLength(254));
      expect(targets.first, '192.168.0.1');
      expect(targets.last, '192.168.0.254');
      // Ağ ve yayın adresleri konak değil.
      expect(targets, isNot(contains('192.168.0.0')));
      expect(targets, isNot(contains('192.168.0.255')));
    });

    test('iki arayüzlü cihazda her iki ağ da taranır', () {
      final targets = CastDiscovery.computeSweepTargets([
        '192.168.0.106',
        '10.0.0.5',
      ]).map((a) => a.address);

      expect(targets, contains('192.168.0.108'));
      expect(targets, contains('10.0.0.42'));
    });

    test('ağ adresi olmayan girdiler tarama üretmez', () {
      expect(
        CastDiscovery.computeSweepTargets(['127.0.0.1', 'fe80::1']),
        isEmpty,
      );
    });
  });

  group('CastClient', () {
    test('videoyu doğru adrese ve biçimde gönderir', () async {
      late http.Request sent;
      final client = CastClient(
        _device,
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response('{"ok":true}', 200);
        }),
      );

      await client.play(
        videoId: 'abc123',
        title: 'Şarkı',
        position: const Duration(seconds: 42),
      );

      expect(sent.url.toString(), 'http://192.168.1.40:45633/cast');
      final body = jsonDecode(utf8.decode(sent.bodyBytes)) as Map;
      expect(body['videoId'], 'abc123');
      // Türkçe karakterler UTF-8 olarak gitmeli; latin1 kodlanırsa
      // televizyonda başlık bozulur.
      expect(body['title'], 'Şarkı');
      expect(body['positionMs'], 42000);
    });

    test('tanınmayan komut gönderilmez', () async {
      final client = CastClient(
        _device,
        httpClient: MockClient((_) async => throw StateError('istek atılmamalı')),
      );

      expect(
        () => client.command('kendi-kendine-patla'),
        throwsA(isA<CastException>()),
      );
    });

    test('ulaşılamayan televizyon anlaşılır bir hataya çevrilir', () async {
      final client = CastClient(
        _device,
        httpClient: MockClient(
          (_) async => throw const SocketException('bağlanılamadı'),
        ),
      );

      await expectLater(
        client.command(CastCommand.pause),
        throwsA(
          isA<CastException>().having(
            (e) => e.message,
            'mesaj',
            allOf(contains('Salon TV'), contains('Wi-Fi')),
          ),
        ),
      );
    });

    test('televizyon isteği reddederse hata verilir', () async {
      final client = CastClient(
        _device,
        httpClient: MockClient((_) async => http.Response('{}', 400)),
      );

      await expectLater(
        client.play(videoId: 'abc', title: 'x'),
        throwsA(isA<CastException>()),
      );
    });

    test('durum okunur', () async {
      final client = CastClient(
        _device,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ok': true,
              'state': {
                'videoId': 'abc',
                'title': 'Şarkı',
                'positionMs': 5000,
                'durationMs': 200000,
                'isPlaying': true,
              },
            }),
            200,
            headers: {
              'content-type': 'application/json; charset=utf-8',
            },
          ),
        ),
      );

      final state = await client.remoteState();

      expect(state!.videoId, 'abc');
      expect(state.position, const Duration(seconds: 5));
      expect(state.duration, const Duration(seconds: 200));
      expect(state.isPlaying, isTrue);
    });

    test('durum alınamazsa null döner, hata fırlatmaz', () async {
      final client = CastClient(
        _device,
        httpClient: MockClient(
          (_) async => throw const SocketException('yok'),
        ),
      );

      expect(await client.remoteState(), isNull);
      expect(await client.ping(), isFalse);
    });
  });

  group('CastController', () {
    late List<MethodCall> playerCalls;

    setUp(() {
      playerCalls = [];
      // Yayın başlayınca telefondaki oynatma duruyor; o çağrı native tarafa
      // gidiyor, testte yakalanıyor.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('olustiff/player'),
        (call) async {
          playerCalls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('olustiff/player'),
        null,
      );
    });

    CastController controllerWith(MockClient http) => CastController(
          clientFactory: (device) => CastClient(device, httpClient: http),
        );

    test('gönderim başarılıysa telefon susar', () async {
      final controller = controllerWith(
        MockClient((_) async => http.Response('{"ok":true}', 200)),
      );

      final ok = await controller.castTo(
        _device,
        videoId: 'abc',
        title: 'Şarkı',
      );

      expect(ok, isTrue);
      expect(controller.isCasting, isTrue);
      expect(controller.device, _device);
      expect(playerCalls.map((c) => c.method), contains('pause'));
      controller.dispose();
    });

    test('televizyona ulaşılamazsa telefon susturulmaz', () async {
      final controller = controllerWith(
        MockClient((_) async => throw const SocketException('yok')),
      );

      final ok = await controller.castTo(
        _device,
        videoId: 'abc',
        title: 'Şarkı',
      );

      expect(ok, isFalse);
      expect(controller.isCasting, isFalse);
      // Kullanıcı hem susmuş bir telefonla hem boş bir televizyonla kalmamalı.
      expect(playerCalls, isEmpty);
      expect(controller.lastError, isNotNull);
      controller.dispose();
    });

    test('komut gönderilince arayüz beklemeden güncellenir', () async {
      final controller = controllerWith(
        MockClient((_) async => http.Response('{"ok":true}', 200)),
      );
      await controller.castTo(_device, videoId: 'abc', title: 'Şarkı');
      expect(controller.remoteState!.isPlaying, isTrue);

      await controller.pause();
      expect(controller.remoteState!.isPlaying, isFalse);

      await controller.seekTo(const Duration(minutes: 2));
      expect(controller.remoteState!.position, const Duration(minutes: 2));
      controller.dispose();
    });

    test('bağlantı kesilince televizyona komut gitmez', () async {
      var requests = 0;
      final controller = controllerWith(
        MockClient((_) async {
          requests++;
          return http.Response('{"ok":true}', 200);
        }),
      );
      await controller.castTo(_device, videoId: 'abc', title: 'Şarkı');
      final afterCast = requests;

      await controller.disconnect();
      await controller.pause();

      expect(controller.isCasting, isFalse);
      expect(requests, afterCast);
      controller.dispose();
    });
  });
}
