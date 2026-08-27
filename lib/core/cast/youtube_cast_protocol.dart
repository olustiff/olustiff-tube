/// Televizyonun KENDİ YouTube uygulamasına video gönderme protokolü.
///
/// Bu dosya yalnızca çözümleme/kodlama içerir (ağ yok), böylece protokolün
/// kırılgan kısımları birim testiyle sabitlenebiliyor.
///
/// ## Neden bu yol — elenenler ve sebepleri
///
/// Hedef: televizyonda oLusTifF KURULU DEĞİLKEN de video gönderebilmek.
/// Üç yol denendi, ikisi gerçek cihazda öldü:
///
/// - **DIAL ile `POST /apps/YouTube`**: en temiz yol olurdu — tamamen yerel,
///   belgelenmiş bir standart. Test edilen Google TV kutusunda ÖLÜ: cihaz
///   SSDP'ye `urn:dial-multiscreen-org:service:dial:1` ile cevap veriyor,
///   `/apps/Netflix` 200 dönüyor ama `/apps/YouTube` 404. YouTube TV
///   uygulaması kurulu (com.google.android.youtube.tv 5.30.320) olmasına
///   rağmen DIAL kaydında yok; cihazın kendi bildirimi de bunu doğruluyor:
///   `dialAdditionalDataSupportLevel: "unsupported"`. Chromecast tabanlı
///   cihazlarda YouTube DIAL'den değil Cast'ten yürüyor.
/// - **Cast `media` ad alanıyla `LOAD`**: YouTube alıcısı standart medya
///   yükleme komutunu `INVALID_COMMAND` ile reddediyor. Alıcı kendi
///   oturumundan besleniyor, dışarıdan URL kabul etmiyor.
/// - **Cast SDK (resmî)**: alıcı kimliğinin Cast Developer Console'a kaydını
///   istiyor ve YouTube'un alıcı kimliği bize ait değil.
///
/// ## Yaşayan yol (gerçek cihazda uçtan uca doğrulandı)
///
/// 1. SSDP ile DIAL cihazını bul (adı `device-desc.xml`'den).
/// 2. Cast v2 (8009/TLS) ile YouTube alıcısını başlat — [youtubeReceiverAppId].
/// 3. `urn:x-cast:com.google.youtube.mdx` ad alanından **screenId** al.
///    Buraya kadarı TAMAMEN YEREL AĞ; kayıt, anahtar, hesap gerekmiyor.
/// 4. screenId'yi Lounge oturumuna çevir ve videoyu kuyruğa koy.
///
/// 4. adım youtube.com üzerinden geçiyor — yani İNTERNET gerekiyor. Bu bir
/// tercih değil, zorunluluk: alıcıya video kimliğini geçirmenin başka yolu
/// yok (yukarıda `LOAD` denendi ve reddedildi). Bizim bir sunucumuz yok;
/// konuşulan taraf, televizyonun zaten bağlı olduğu Google altyapısı.
/// Uygulama zaten videoları internetten çeken bir YouTube istemcisi olduğu
/// için bu yeni bir bağımlılık da değil.
///
/// Lounge resmî olarak belgelenmiş DEĞİL; Google istediği an değiştirebilir.
/// Bu yüzden her adım sessizce değil, sebebini söyleyen bir hatayla
/// başarısız oluyor ve arayüz yalnızca gerçekten çalışan kontrolleri
/// gösteriyor (bkz. [YouTubeCastSession]).
library;

import 'dart:convert';
import 'dart:typed_data';

/// YouTube'un Cast alıcı uygulamasının kimliği.
///
/// Sabit ve herkese açık: kayıt gerektirmeyen, cihazın kendi kurulu YouTube
/// uygulamasını açan kimlik. Bizim adımıza bir şey iddia etmiyoruz — yalnızca
/// televizyona "kendi YouTube'unu aç" diyoruz.
const String youtubeReceiverAppId = '233637DE';

/// Cast v2 denetim portu (TLS). Chromecast tabanlı bütün cihazlarda sabit.
const int castV2Port = 8009;

/// DIAL/SSDP tanıtım sunucusunun portu; cihaz adı buradan okunuyor.
const int dialDescriptionPort = 8008;

/// SSDP'de aradığımız hizmet türü.
const String dialSearchTarget = 'urn:dial-multiscreen-org:service:dial:1';

/// Cast v2 ad alanları.
class CastNamespace {
  static const String connection = 'urn:x-cast:com.google.cast.tp.connection';
  static const String heartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const String receiver = 'urn:x-cast:com.google.cast.receiver';

  /// YouTube alıcısının kendi ad alanı; screenId buradan geliyor.
  static const String youtubeMdx = 'urn:x-cast:com.google.youtube.mdx';
}

/// Televizyonun kendi YouTube uygulamasına gönderim yapılabilen cihaz.
///
/// Bizim [CastDevice]'ımızdan AYRI bir tür: o "televizyonda oLusTifF çalışıyor"
/// demek, bu "televizyonun kendi YouTube'u var" demek. İkisini tek türde
/// birleştirmek, arayüzde hangi yolun kullanılacağını belirsizleştirirdi.
class YouTubeCastDevice {
  const YouTubeCastDevice({
    required this.id,
    required this.name,
    required this.host,
  });

  /// Cihazın UPnP kimliği (UDN). IP değişse de sabit kalır.
  final String id;

  /// Kullanıcıya gösterilen ad ("Oturma Odası TV'si").
  final String name;

  final String host;

  @override
  bool operator ==(Object other) => other is YouTubeCastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'YouTubeCastDevice($name @ $host)';
}

/// SSDP cevabından ihtiyacımız olan alanlar.
class SsdpResponse {
  const SsdpResponse({required this.location, required this.usn});

  /// Cihaz tanıtım belgesinin adresi.
  final String location;

  /// Cihazı benzersiz tanımlayan kimlik.
  final String usn;

  /// `USN`'in içindeki `uuid:...` kısmı; hizmet son ekleri atılır.
  ///
  /// Aynı cihaz farklı hizmetler için farklı USN gönderiyor
  /// (`uuid:X::upnp:rootdevice`, `uuid:X::urn:dial...`); son eki atmadan
  /// teklemek aynı televizyonu listede iki kez gösterirdi.
  String get deviceId {
    final cut = usn.indexOf('::');
    return cut == -1 ? usn : usn.substring(0, cut);
  }
}

/// SSDP cevabını çözer; bize ait olmayan/eksik cevaplarda null döner.
///
/// Ağda dolaşan her UDP paketi SSDP değil ve her SSDP cevabı DIAL değil —
/// eksik alan hata değil, "bu cihaz bizi ilgilendirmiyor" demek.
SsdpResponse? parseSsdpResponse(String raw) {
  final lines = const LineSplitter().convert(raw);
  if (lines.isEmpty) return null;
  // İlk satır durum satırı olmalı; NOTIFY duyuruları da kabul ediliyor çünkü
  // cihaz kendiliğinden duyuru yapmış olabilir.
  final status = lines.first.toUpperCase();
  if (!status.startsWith('HTTP/1.1 200') && !status.startsWith('NOTIFY')) {
    return null;
  }

  String? location;
  String? usn;
  for (final line in lines.skip(1)) {
    final split = line.indexOf(':');
    if (split <= 0) continue;
    final key = line.substring(0, split).trim().toUpperCase();
    final value = line.substring(split + 1).trim();
    if (key == 'LOCATION') location = value;
    if (key == 'USN') usn = value;
  }

  if (location == null || location.isEmpty) return null;
  if (usn == null || usn.isEmpty) return null;
  return SsdpResponse(location: location, usn: usn);
}

/// SSDP arama paketini üretir.
///
/// [host] her zaman çok noktaya yayın adresi yazıyor — paket tek bir cihaza
/// (unicast) gönderilse bile: SSDP standardı `HOST` alanının bu değeri
/// taşımasını istiyor ve bazı cihazlar farklı yazıldığında cevap vermiyor.
String encodeSsdpSearch({int maxWaitSeconds = 2}) => 'M-SEARCH * HTTP/1.1\r\n'
    'HOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $maxWaitSeconds\r\n'
    'ST: $dialSearchTarget\r\n'
    '\r\n';

/// Cihaz tanıtım belgesinden kullanıcıya gösterilecek adı çıkarır.
///
/// Tam bir XML çözümleyici yerine tek etiket araması: belge sabit ve küçük,
/// yalnızca tek bir alan gerekiyor. Ad okunamazsa null döner ve çağıran
/// taraf adresi gösterir — cihazı listeden düşürmek gerekmez.
String? parseFriendlyName(String xml) {
  final match = RegExp(
    r'<friendlyName>(.*?)</friendlyName>',
    dotAll: true,
  ).firstMatch(xml);
  final raw = match?.group(1)?.trim();
  if (raw == null || raw.isEmpty) return null;
  return _unescapeXml(raw);
}

/// XML varlık kaçışlarını çözer.
///
/// Gerçek bir cihazda karşılaşıldı: "Oturma Odası TV'si" belgede
/// `Oturma Odası TV&#39;si` olarak geliyor ve ham hâliyle gösterilince
/// kullanıcı adını tanıyamıyor.
String _unescapeXml(String value) {
  var out = value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
  out = out.replaceAllMapped(
    RegExp(r'&#(x?)([0-9a-fA-F]+);'),
    (m) {
      final isHex = m.group(1)!.isNotEmpty;
      final code = int.tryParse(m.group(2)!, radix: isHex ? 16 : 10);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    },
  );
  // `&amp;` EN SONA bırakılıyor: önce çözülürse "&amp;lt;" gibi çift kaçışlı
  // diziler yanlışlıkla ikinci kez çözülürdü.
  return out.replaceAll('&amp;', '&');
}

// ---------------------------------------------------------------------------
// Cast v2 çerçeveleme
// ---------------------------------------------------------------------------

/// Cast v2 mesajı: 4 baytlık uzunluk öneki + protobuf gövde.
///
/// Protobuf elle kodlanıyor; hazır bir üretici eklemek yalnızca altı alanlık
/// tek bir mesaj için bütün derleme zincirine bağımlılık getirirdi.
///
/// `CastMessage` alanları:
/// 1 protocol_version (0), 2 source_id, 3 destination_id, 4 namespace,
/// 5 payload_type (0 = STRING), 6 payload_utf8.
Uint8List encodeCastMessage({
  required String sourceId,
  required String destinationId,
  required String namespace,
  required String payload,
}) {
  final body = BytesBuilder()
    ..add(_protoVarintField(1, 0))
    ..add(_protoStringField(2, sourceId))
    ..add(_protoStringField(3, destinationId))
    ..add(_protoStringField(4, namespace))
    ..add(_protoVarintField(5, 0))
    ..add(_protoStringField(6, payload));

  final bytes = body.takeBytes();
  final framed = BytesBuilder()
    ..add([
      (bytes.length >> 24) & 0xff,
      (bytes.length >> 16) & 0xff,
      (bytes.length >> 8) & 0xff,
      bytes.length & 0xff,
    ])
    ..add(bytes);
  return framed.takeBytes();
}

/// Çözülmüş bir Cast v2 mesajı.
class CastMessage {
  const CastMessage({required this.namespace, required this.payload});

  final String namespace;
  final String payload;

  /// Gövdeyi JSON olarak okur; JSON değilse null.
  Map<String, Object?>? get json {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }
}

/// TCP akışından gelen parçaları tam Cast mesajlarına böler.
///
/// Ayrı bir sınıf çünkü TLS soketi mesaj sınırlarını korumuyor: tek bir
/// `recv` yarım mesaj da getirebilir, üst üste üç mesaj da. Sınır yönetimi
/// tek yerde durmazsa protokol rastgele bozuluyor.
class CastFrameReader {
  final BytesBuilder _buffer = BytesBuilder();

  /// Gelen baytları ekler ve tamamlanan mesajları döner.
  List<CastMessage> add(List<int> chunk) {
    _buffer.add(chunk);
    var bytes = _buffer.takeBytes();
    final messages = <CastMessage>[];

    var offset = 0;
    while (bytes.length - offset >= 4) {
      final length = (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      // Bozuk uzunluk: akış senkronunu kaybettik, tamponu atmak sonsuz
      // büyümeden iyidir.
      if (length < 0 || length > 1 << 22) {
        offset = bytes.length;
        break;
      }
      if (bytes.length - offset - 4 < length) break;
      final body = bytes.sublist(offset + 4, offset + 4 + length);
      offset += 4 + length;
      final message = _decodeCastMessage(body);
      if (message != null) messages.add(message);
    }

    // Kalan yarım mesaj bir sonraki parçayı bekliyor.
    if (offset < bytes.length) _buffer.add(bytes.sublist(offset));
    return messages;
  }
}

/// Protobuf gövdesinden yalnızca ad alanı ve yükü çıkarır.
///
/// Diğer alanlar atlanıyor: gönderen/alıcı kimliğiyle işimiz yok ve tam bir
/// protobuf çözümleyicisi yazmak bu iş için gereksiz.
CastMessage? _decodeCastMessage(Uint8List body) {
  var i = 0;
  String? namespace;
  String? payload;

  int? readVarint() {
    var result = 0;
    var shift = 0;
    while (i < body.length) {
      final byte = body[i++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) return null;
    }
    return null;
  }

  while (i < body.length) {
    final key = readVarint();
    if (key == null) return null;
    final field = key >> 3;
    final wireType = key & 0x07;

    if (wireType == 0) {
      if (readVarint() == null) return null;
    } else if (wireType == 2) {
      final length = readVarint();
      if (length == null || i + length > body.length) return null;
      final value = body.sublist(i, i + length);
      i += length;
      if (field == 4) namespace = utf8.decode(value, allowMalformed: true);
      if (field == 6) payload = utf8.decode(value, allowMalformed: true);
    } else {
      // Beklenmeyen tel biçimi: mesajın kalanı güvenilir değil.
      return null;
    }
  }

  if (namespace == null) return null;
  return CastMessage(namespace: namespace, payload: payload ?? '');
}

List<int> _protoVarintField(int field, int value) =>
    [...(_varint((field << 3) | 0)), ...(_varint(value))];

List<int> _protoStringField(int field, String value) {
  final bytes = utf8.encode(value);
  return [...(_varint((field << 3) | 2)), ...(_varint(bytes.length)), ...bytes];
}

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  do {
    var byte = v & 0x7f;
    v >>= 7;
    if (v != 0) byte |= 0x80;
    out.add(byte);
  } while (v != 0);
  return out;
}

// ---------------------------------------------------------------------------
// Lounge oturumu
// ---------------------------------------------------------------------------

/// Lounge oturumunun komut göndermek için gereken kimlikleri.
class LoungeSession {
  const LoungeSession({
    required this.loungeToken,
    required this.sessionId,
    required this.gSessionId,
  });

  final String loungeToken;

  /// `SID` — oturum kimliği.
  final String sessionId;

  /// `gsessionid` — sunucu tarafı oturum kimliği.
  final String gSessionId;
}

/// Lounge'ın `bind` cevabındaki tek bir olay.
class LoungeEvent {
  const LoungeEvent({required this.index, required this.name, this.payload});

  /// Olay sırası (`AID` olarak geri bildiriliyor).
  final int index;
  final String name;
  final Object? payload;
}

/// Lounge cevabını olaylara böler.
///
/// Biçim: `<uzunluk>\n<json>` ardışık tekrarı. Uzunluk BAYT cinsinden, bu
/// yüzden çözümleme metin üzerinde değil bayt üzerinde yapılıyor — cihaz
/// adları Türkçe karakter içerdiğinde metin uzunluğu bayt uzunluğundan
/// küçük kalıyor ve bütün çerçeveleme kayıyordu.
///
/// Bozuk/yarım cevapta o ana kadar çözülenler dönüyor: elde olanla devam
/// etmek, her şeyi atmaktan iyi.
List<LoungeEvent> parseLoungeEvents(List<int> bytes) {
  final events = <LoungeEvent>[];
  var offset = 0;

  while (offset < bytes.length) {
    // Uzunluk öneki: satır sonuna kadar rakamlar.
    var cursor = offset;
    final digits = <int>[];
    while (cursor < bytes.length && bytes[cursor] != 0x0a) {
      digits.add(bytes[cursor]);
      cursor++;
    }
    if (cursor >= bytes.length) break;
    final length = int.tryParse(String.fromCharCodes(digits).trim());
    if (length == null || length <= 0) break;

    final start = cursor + 1;
    final end = start + length;
    if (end > bytes.length) break;

    final chunk = utf8.decode(bytes.sublist(start, end), allowMalformed: true);
    offset = end;

    final Object? decoded;
    try {
      decoded = jsonDecode(chunk);
    } catch (_) {
      // Tek bir bozuk parça bütün cevabı çöpe atmamalı.
      continue;
    }
    if (decoded is! List) continue;

    for (final entry in decoded) {
      if (entry is! List || entry.length < 2) continue;
      final index = entry[0];
      final body = entry[1];
      if (index is! num || body is! List || body.isEmpty) continue;
      final name = body.first;
      if (name is! String) continue;
      events.add(
        LoungeEvent(
          index: index.toInt(),
          name: name,
          payload: body.length > 1 ? body[1] : null,
        ),
      );
    }
  }

  return events;
}

/// `bind` cevabından oturum kimliklerini çıkarır.
///
/// `c` olayı SID'yi, `S` olayı gsessionid'yi taşıyor. İkisinden biri
/// eksikse oturum kurulmamış sayılıyor: yarım kimlikle komut göndermek
/// sessizce başarısız olurdu.
LoungeSession? extractLoungeSession(
  List<LoungeEvent> events, {
  required String loungeToken,
}) {
  String? sessionId;
  String? gSessionId;
  for (final event in events) {
    final payload = event.payload;
    if (payload is! String || payload.isEmpty) continue;
    if (event.name == 'c') sessionId = payload;
    if (event.name == 'S') gSessionId = payload;
  }
  if (sessionId == null || gSessionId == null) return null;
  return LoungeSession(
    loungeToken: loungeToken,
    sessionId: sessionId,
    gSessionId: gSessionId,
  );
}

/// Olay listesindeki en büyük sıra numarası (`AID`).
///
/// Sunucuya "buraya kadarını aldım" demek için gerekiyor; yanlış bildirmek
/// aynı olayların tekrar tekrar gelmesine yol açıyor.
int lastLoungeEventIndex(List<LoungeEvent> events) {
  var last = 0;
  for (final event in events) {
    if (event.index > last) last = event.index;
  }
  return last;
}

/// `get_lounge_token_batch` cevabından belirteci çıkarır.
String? parseLoungeToken(String body, {required String screenId}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final screens = decoded['screens'];
  if (screens is! List) return null;
  for (final screen in screens) {
    if (screen is! Map) continue;
    // Toplu uç nokta birden çok ekran dönebiliyor; kimliği eşleşeni alıyoruz.
    if (screen['screenId'] != screenId) continue;
    final token = screen['loungeToken'];
    if (token is String && token.isNotEmpty) return token;
  }
  return null;
}

/// Lounge komutları.
///
/// Ad listesi sabit: yanlış yazılmış bir komut adı sunucudan 200 dönüyor ama
/// televizyonda hiçbir şey olmuyor — sessiz başarısızlığın en kötü türü.
class LoungeCommand {
  /// Kuyruğu tek videoyla değiştirir ve oynatmayı başlatır.
  static const String setPlaylist = 'setPlaylist';
  static const String play = 'play';
  static const String pause = 'pause';
  static const String seekTo = 'seekTo';
  static const String next = 'next';
  static const String previous = 'previous';

  /// Alıcıyı durdurur (televizyondaki YouTube boşta ekrana döner).
  static const String stop = 'stopVideo';
}
