import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:olustiff/core/cast/cast_client.dart';
import 'package:olustiff/core/cast/cast_controller.dart';
import 'package:olustiff/core/cast/cast_discovery.dart';
import 'package:olustiff/core/cast/cast_protocol.dart';
import 'package:olustiff/core/extraction/models.dart';
import 'package:olustiff/core/playback/playback_coordinator.dart';
import 'package:olustiff/core/playback/ui_channel.dart';
import 'package:olustiff/features/settings/cast_receiver_setting.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // Yayın başlarken telefonun oynatıcısı susturuluyor ve ses tuşları
  // televizyona yönlendiriliyor; ikisi de native kanaldan geçiyor.
  void mock(String channel, Future<Object?> Function(MethodCall)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channel), handler);
  }

  setUp(() {
    mock('olustiff/player', (_) async => null);
    mock('olustiff/ui', (_) async => null);
  });

  tearDown(() {
    mock('olustiff/player', null);
    mock('olustiff/ui', null);
  });

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

    test('televizyonda uygulama kapalıysa sebebi anlaşılır söylenir', () async {
      // Alıcı açılıştan beri çalışıyor, yani televizyon LİSTEDE görünür;
      // ama orada oynatma yoksa kumanda komutunun karşılığı yok. Kullanıcı
      // "503" değil, ne yapması gerektiğini görmeli.
      final client = CastClient(
        _device,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'ok': false, 'error': 'app_not_running'}),
            503,
          ),
        ),
      );

      await expectLater(
        client.command(CastCommand.pause),
        throwsA(
          isA<CastException>().having(
            (e) => e.message,
            'mesaj',
            allOf(contains('çalan bir şey yok'), isNot(contains('503'))),
          ),
        ),
      );
    });

    test('tanınmayan hata kodunda durum kodu gösterilir', () async {
      final client = CastClient(
        _device,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'ok': false, 'error': 'bilinmeyen_sebep'}),
            500,
          ),
        ),
      );

      await expectLater(
        client.command(CastCommand.pause),
        throwsA(
          isA<CastException>()
              .having((e) => e.message, 'mesaj', contains('500')),
        ),
      );
    });

    test('JSON olmayan hata gövdesi istisna fırlatmaz', () async {
      // Ağdaki bir vekil sunucu araya HTML hata sayfası koyabiliyor;
      // bunu çözmeye çalışırken patlamak, hatayı hiç göstermemek olurdu.
      final client = CastClient(
        _device,
        httpClient: MockClient(
          // Gövde düz ASCII: http paketi charset verilmediğinde latin1
          // varsayıyor ve Türkçe karakterli bir gövde testin kendi
          // kurulumunda patlıyor.
          (_) async => http.Response('<html>bad gateway</html>', 502),
        ),
      );

      await expectLater(
        client.command(CastCommand.pause),
        throwsA(
          isA<CastException>()
              .having((e) => e.message, 'mesaj', contains('502')),
        ),
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


  group('ses kontrolü', () {
    late List<Map<String, Object?>> commands;

    CastController controllerWith() {
      commands = [];
      return CastController(
        clientFactory: (device) => CastClient(
          device,
          httpClient: MockClient((request) async {
            if (request.url.path == '/command') {
              commands.add(
                jsonDecode(utf8.decode(request.bodyBytes))
                    as Map<String, Object?>,
              );
            }
            return http.Response('{"ok":true}', 200);
          }),
        ),
      );
    }

    Future<CastController> casting() async {
      final controller = controllerWith();
      await controller.castTo(_device, videoId: 'abc', title: 'Şarkı');
      // Televizyonun bildirdiği ses seviyesi olmadan kaydırıcı gösterilmiyor.
      controller.applyRemoteStateForTest(
        const CastRemoteState(videoId: 'abc', volume: 0.5),
      );
      return controller;
    }

    test('mutlak ses seviyesi gönderilir', () async {
      final controller = await casting();

      await controller.setVolume(0.8);

      expect(commands.last['action'], CastCommand.volume);
      expect(commands.last['volume'], 0.8);
      // Arayüz yoklamayı beklemeden yeni seviyeyi gösterir.
      expect(controller.volume, 0.8);
      controller.dispose();
    });

    test('ses seviyesi 0..1 aralığına sıkıştırılır', () async {
      final controller = await casting();

      await controller.setVolume(1.7);

      expect(commands.last['volume'], 1.0);
      controller.dispose();
    });

    test('bir kademe artırma sessizliği de bozar', () async {
      final controller = await casting();
      controller.applyRemoteStateForTest(
        const CastRemoteState(videoId: 'abc', volume: 0.5, isMuted: true),
      );

      await controller.volumeUp();

      expect(commands.last['action'], CastCommand.volumeUp);
      expect(controller.volume, closeTo(0.52, 0.0001));
      expect(controller.isMuted, isFalse);
      controller.dispose();
    });

    test('kademe azaltma sıfırın altına inmez', () async {
      final controller = await casting();
      controller.applyRemoteStateForTest(
        const CastRemoteState(videoId: 'abc', volume: 0.02),
      );

      await controller.volumeDown();

      expect(controller.volume, 0.0);
      controller.dispose();
    });

    test('sessize alma aç/kapa çalışır', () async {
      final controller = await casting();

      await controller.toggleMute();
      expect(commands.last['action'], CastCommand.mute);
      expect(controller.isMuted, isTrue);

      await controller.toggleMute();
      expect(controller.isMuted, isFalse);
      controller.dispose();
    });

    test('televizyon ses seviyesini bildirmiyorsa tahmin yürütülmez', () async {
      final controller = controllerWith();
      await controller.castTo(_device, videoId: 'abc', title: 'Şarkı');

      await controller.volumeUp();

      expect(controller.volume, isNull);
      controller.dispose();
    });
  });

  group('kopan oturum', () {
    test('televizyon cevap vermeyi bırakınca yayın kapanır', () async {
      var reachable = true;
      final controller = CastController(
        pollInterval: const Duration(milliseconds: 20),
        clientFactory: (device) => CastClient(
          device,
          httpClient: MockClient((request) async {
            if (!reachable) throw const SocketException('yok');
            return http.Response(
              request.url.path == '/state'
                  ? '{"ok":true,"state":{"positionMs":0}}'
                  : '{"ok":true}',
              200,
            );
          }),
        ),
      );
      await controller.castTo(_device, videoId: 'abc', title: 'Şarkı');
      expect(controller.isCasting, isTrue);

      reachable = false;
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Kullanıcı ölü bir kumandayla kalmamalı.
      expect(controller.isCasting, isFalse);
      expect(controller.lastError, contains('koptu'));
      controller.dispose();
    });

    test('tek bir cevapsız yoklama oturumu bitirmez', () async {
      var failNext = true;
      final controller = CastController(
        pollInterval: const Duration(milliseconds: 20),
        clientFactory: (device) => CastClient(
          device,
          httpClient: MockClient((request) async {
            if (request.url.path == '/state' && failNext) {
              failNext = false;
              throw const SocketException('geçici');
            }
            return http.Response(
              request.url.path == '/state'
                  ? '{"ok":true,"state":{"positionMs":0}}'
                  : '{"ok":true}',
              200,
            );
          }),
        ),
      );
      await controller.castTo(_device, videoId: 'abc', title: 'Şarkı');

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(controller.isCasting, isTrue);
      controller.dispose();
    });
  });

  group('oturum yönetimi', () {
    test('başka televizyona geçilince eskisi durdurulur', () async {
      final commands = <String>[];
      final controller = CastController(
        clientFactory: (device) => CastClient(
          device,
          httpClient: MockClient((request) async {
            if (request.url.path == '/command') {
              commands.add(
                '${request.url.host}:'
                '${(jsonDecode(utf8.decode(request.bodyBytes)) as Map)['action']}',
              );
            }
            return http.Response('{"ok":true}', 200);
          }),
        ),
      );
      await controller.castTo(_device, videoId: 'a', title: 'A');

      const other = CastDevice(
        id: 'tv-2',
        name: 'Yatak Odası',
        host: '192.168.1.41',
        port: castControlPort,
      );
      await controller.castTo(other, videoId: 'b', title: 'B');

      // Kullanıcı artık kumanda edemediği bir televizyonu çalar bırakmamalı.
      expect(commands, contains('192.168.1.40:stop'));
      expect(controller.device, other);
      controller.dispose();
    });

    test('ses seviyesi yeni videoda kaybolmaz', () async {
      final controller = CastController(
        clientFactory: (device) => CastClient(
          device,
          httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
        ),
      );
      await controller.castTo(_device, videoId: 'a', title: 'A');
      controller.applyRemoteStateForTest(
        const CastRemoteState(videoId: 'a', volume: 0.4),
      );

      await controller.castTo(_device, videoId: 'b', title: 'B');

      expect(controller.volume, 0.4);
      controller.dispose();
    });
  });

  group('yayın açıkken oynatma', () {
    late List<String> castedVideos;
    late List<MethodCall> playerCalls;
    late bool castFails;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      castedVideos = [];
      playerCalls = [];
      castFails = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('olustiff/extractor'),
        (call) async => call.method == 'videoDetails'
            ? {
                'videoId': call.arguments['videoId'],
                'title': 'Video ${call.arguments['videoId']}',
                'uploaderName': 'Kanal',
                'durationSeconds': 100,
                'viewCount': 1,
                'description': '',
                'tags': <String>[],
                'isLive': false,
                'videoStreams': <Object?>[],
                'videoOnlyStreams': <Object?>[],
                'audioStreams': <Object?>[],
                'relatedItems': <Object?>[],
              }
            : null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('olustiff/player'),
        (call) async {
          playerCalls.add(call);
          return null;
        },
      );

      CastController.overrideInstance(
        CastController(
          clientFactory: (device) => CastClient(
            device,
            httpClient: MockClient((request) async {
              if (request.url.path == '/cast') {
                if (castFails) throw const SocketException('ulaşılamadı');
                castedVideos.add(
                  (jsonDecode(utf8.decode(request.bodyBytes))
                      as Map)['videoId'] as String,
                );
              }
              return http.Response('{"ok":true}', 200);
            }),
          ),
        ),
      );
      await CastController.instance
          .castTo(_device, videoId: 'ilk', title: 'İlk');
      playerCalls.clear();
    });

    tearDown(() {
      CastController.instance.dispose();
      CastController.resetInstance();
      for (final name in ['olustiff/extractor', 'olustiff/player']) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(name), null);
      }
    });

    // Kullanıcının bulduğu hata: yayın açıkken listeden seçilen video
    // telefonda çalmaya başlıyor, düğmeler ise televizyondakini yönetiyordu.
    test('yeni seçilen video televizyona gider, telefonda çalmaz', () async {
      await PlaybackCoordinator.instance.play('yeni');

      expect(castedVideos, contains('yeni'));
      expect(
        playerCalls.map((c) => c.method),
        isNot(contains('play')),
        reason: 'telefonun kendi oynatıcısı hiç başlamamalı',
      );
      expect(PlaybackCoordinator.instance.details?.videoId, 'yeni');
    });

    test('telefonun geç gelen durum bildirimi ekranı geri almaz', () async {
      await PlaybackCoordinator.instance.play('yeni');

      // Telefonun oynatıcısı hâlâ ESKİ medyayı bildiriyor.
      await PlaybackCoordinator.instance.syncFromNative('eski', 0);

      expect(PlaybackCoordinator.instance.details?.videoId, 'yeni');
    });

    test('telefonun oynatıcısı durdu diye televizyondaki silinmez', () async {
      await PlaybackCoordinator.instance.play('yeni');

      PlaybackCoordinator.instance.handleStoppedExternally();

      expect(PlaybackCoordinator.instance.details?.videoId, 'yeni');
    });

    // İnceleme bulgusu: kuyruk bir ÖNCEKİ oynatmanın listesinden kuruluyordu.
    test('kuyruk yeni seçilen listeden kurulur', () async {
      const first = VideoSummary(
        videoId: 'a',
        title: 'A',
        url: 'u',
        uploaderName: 'K',
        durationSeconds: 10,
        viewCount: 1,
        textualUploadDate: null,
        thumbnailUrl: null,
      );
      const second = VideoSummary(
        videoId: 'b',
        title: 'B',
        url: 'u',
        uploaderName: 'K',
        durationSeconds: 10,
        viewCount: 1,
        textualUploadDate: null,
        thumbnailUrl: null,
      );

      await PlaybackCoordinator.instance.play('a', context: [first]);
      await PlaybackCoordinator.instance.play('b', context: [second]);

      expect(
        PlaybackCoordinator.instance.queue.map((v) => v.videoId),
        isNot(contains('a')),
        reason: 'eski listenin videosu yeni kuyruğa sızmamalı',
      );
    });

    test('gönderim başarısızsa video televizyonda çalıyor gibi gösterilmez',
        () async {
      await PlaybackCoordinator.instance.play('yeni');
      castFails = true;

      await PlaybackCoordinator.instance.play('ulasilamayan');

      // Telefon, televizyonda çalmayan bir videoyu "TV'de oynatılıyor" diye
      // göstermemeli; hata ekrana çıkmalı.
      expect(PlaybackCoordinator.instance.details?.videoId,
          isNot('ulasilamayan'));
      expect(PlaybackCoordinator.instance.lastError, isNotNull);
    });

    test('oynat/duraklat komutu televizyona gider', () async {
      await PlaybackCoordinator.instance.pause();
      await PlaybackCoordinator.instance.resume();

      expect(
        playerCalls.map((c) => c.method),
        isNot(anyOf(contains('pause'), contains('resume'))),
        reason: 'telefonda ikinci bir ses başlamamalı',
      );
    });

    test('sıradakine geçme komutu televizyona gider', () async {
      await PlaybackCoordinator.instance.playNext();

      expect(
        playerCalls.map((c) => c.method),
        isNot(contains('next')),
        reason: 'telefonun sessiz oynatıcısını ilerletmenin anlamı yok',
      );
    });
  });

  // Televizyondaki alıcı açılıştan beri çalışıyor; ama uygulama KAPALIYKEN
  // gelen videoyu ekrana getirmek "diğer uygulamaların üzerinde göster"
  // iznine bağlı. İzin yoksa özellik yarım çalışır ve bunu kullanıcıya
  // açıkça söylemek gerekiyor.
  group('televizyonda yayın izni', () {
    test('eski kurulumda yöntem yoksa izin yok sayılır', () async {
      // Kanal yöntemi tanımıyorsa istisna fırlıyor; bu bir çökme sebebi
      // değil, "izin yok" demek.
      mock('olustiff/ui', (call) async {
        if (call.method == 'canDrawOverlays') {
          throw MissingPluginException('yok');
        }
        return null;
      });

      expect(await UiChannel.instance.canDrawOverlays(), isFalse);
    });

    test('izin verilmişse true döner', () async {
      mock('olustiff/ui', (call) async {
        if (call.method == 'canDrawOverlays') return true;
        return null;
      });

      expect(await UiChannel.instance.canDrawOverlays(), isTrue);
    });

    testWidgets('izin yokken uyarı ve izin düğmesi gösterilir', (tester) async {
      mock('olustiff/ui', (call) async {
        if (call.method == 'canDrawOverlays') return false;
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CastReceiverSetting())),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('yarım çalışıyor'), findsOneWidget);
      expect(find.text('İzin ver'), findsOneWidget);
    });

    testWidgets('izin varken hazır olduğu söylenir', (tester) async {
      mock('olustiff/ui', (call) async {
        if (call.method == 'canDrawOverlays') return true;
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CastReceiverSetting())),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Hazır'), findsOneWidget);
      // Uyarı kartı ve izin düğmesi ORTADAN KALKMALI: verilmiş bir izni
      // tekrar istemek kullanıcıyı "bir şey eksik" sanmaya itiyordu.
      expect(find.text('İzin ver'), findsNothing);
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
