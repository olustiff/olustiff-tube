import 'dart:convert';

/// Telefon ↔ televizyon arasındaki yayın (cast) protokolü.
///
/// Neden hazır bir çözüm değil de kendi protokolümüz:
/// - Google Cast SDK'sı, alıcı uygulamanın Cast Developer Console'a
///   kaydedilip bir uygulama kimliği alınmasını ve alıcı cihazın geliştirici
///   olarak tanıtılmasını şart koşuyor. Bu uygulama mağazaya girmeyecek, o
///   yüzden o yol pratikte kapalı.
/// - DIAL / YouTube Lounge yolu resmî değil; Google istediği an kesebilir ve
///   kesildiğinde elimizde hiçbir kontrol kalmaz.
///
/// İki uçta da BİZİM uygulamamız çalıştığı için en sade yol yetiyor: UDP
/// yayınıyla keşif, HTTP ile komut. Kayıt yok, bulut yok, bağımlılık yok.
library;

/// Keşif paketlerinin gittiği port (televizyon burayı dinler).
const int castDiscoveryPort = 45632;

/// Komutların gittiği HTTP portu (televizyon burada sunucu açar).
const int castControlPort = 45633;

/// Uyumsuz sürümlerin birbirini yanlış anlamaması için.
const int castProtocolVersion = 1;

/// Ağdaki başka uygulamaların paketlerini kendi paketimiz sanmamak için
/// her mesajda taşınan imza.
const String castMagic = 'olustiff-cast';

const String _typeDiscover = 'discover';
const String _typeDevice = 'device';

/// Yayın yapılabilecek bir televizyon.
class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.appVersion,
  });

  /// Cihazı ağ adresinden BAĞIMSIZ tanımlar. IP, DHCP kirası yenilendiğinde
  /// değişebiliyor; "en son şu televizyona gönderdim" bilgisini adrese
  /// bağlamak yanlış cihaza gönderme riski taşır.
  final String id;

  /// Kullanıcıya gösterilen ad (televizyonun kendi cihaz adı).
  final String name;

  final String host;
  final int port;

  /// Televizyondaki uygulamanın sürümü; uyumsuzluk teşhisini kolaylaştırır.
  final String? appVersion;

  Uri endpoint(String path) => Uri.parse('http://$host:$port$path');

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CastDevice($name @ $host:$port)';
}

/// Telefonun ağa saldığı "orada kimse var mı" paketi.
String encodeDiscoveryProbe() => jsonEncode({
      'm': castMagic,
      't': _typeDiscover,
      'v': castProtocolVersion,
    });

/// Gelen paket bize ait bir keşif isteği mi.
///
/// Televizyon tarafı bunu Kotlin'de uyguluyor; buradaki kopya biçimi tek bir
/// yerde tanımlı tutmak ve test edebilmek için var.
bool isDiscoveryProbe(String raw) {
  final map = _decode(raw);
  if (map == null) return false;
  return map['m'] == castMagic && map['t'] == _typeDiscover;
}

/// Televizyonun keşif isteğine verdiği cevap.
String encodeDeviceAnnouncement({
  required String id,
  required String name,
  int port = castControlPort,
  String? appVersion,
}) =>
    jsonEncode({
      'm': castMagic,
      't': _typeDevice,
      'v': castProtocolVersion,
      'id': id,
      'name': name,
      'port': port,
      if (appVersion != null) 'app': appVersion,
    });

/// Televizyonun cevabını çözer.
///
/// [host] paketi GÖNDEREN adres: televizyon kendi IP'sini bildirmiyor, çünkü
/// çok arayüzlü cihazlarda (Ethernet + Wi-Fi) hangi adresten ulaşılabildiğini
/// yalnızca alıcı taraf bilir.
///
/// Bize ait olmayan ya da bozuk paketlerde null döner — ağda başka
/// uygulamaların yayınları da dolaşıyor, hiçbiri hata sayılmaz.
CastDevice? parseDeviceAnnouncement(String raw, String host) {
  final map = _decode(raw);
  if (map == null) return null;
  if (map['m'] != castMagic || map['t'] != _typeDevice) return null;
  // Sürüm uyuşmazlığında cihazı hiç göstermiyoruz: yarım anlaşılan bir
  // protokolle komut göndermek, hiç göndermemekten kötü.
  if (map['v'] != castProtocolVersion) return null;

  final id = map['id'];
  final name = map['name'];
  if (id is! String || id.isEmpty) return null;
  if (name is! String || name.isEmpty) return null;

  final port = map['port'];
  final resolvedPort = port is num ? port.toInt() : castControlPort;
  if (resolvedPort <= 0 || resolvedPort > 65535) return null;

  final app = map['app'];

  return CastDevice(
    id: id,
    name: name,
    host: host,
    port: resolvedPort,
    appVersion: app is String ? app : null,
  );
}

/// Televizyonda çalanın telefona bildirilen özeti.
class CastRemoteState {
  const CastRemoteState({
    this.videoId,
    this.title,
    this.position = Duration.zero,
    this.duration,
    this.isPlaying = false,
  });

  final String? videoId;
  final String? title;
  final Duration position;
  final Duration? duration;
  final bool isPlaying;

  Map<String, Object?> toJson() => {
        'videoId': videoId,
        'title': title,
        'positionMs': position.inMilliseconds,
        'durationMs': duration?.inMilliseconds,
        'isPlaying': isPlaying,
      };

  static CastRemoteState? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final durationMs = raw['durationMs'];
    return CastRemoteState(
      videoId: raw['videoId'] as String?,
      title: raw['title'] as String?,
      position: Duration(
        milliseconds: (raw['positionMs'] as num?)?.toInt() ?? 0,
      ),
      duration: durationMs is num
          ? Duration(milliseconds: durationMs.toInt())
          : null,
      isPlaying: raw['isPlaying'] as bool? ?? false,
    );
  }
}

/// Televizyona gönderilebilen uzaktan kumanda komutları.
///
/// Sabit bir liste: televizyon tanımadığı komutu reddediyor, böylece sürüm
/// farkı olan iki uç sessizce yanlış iş yapmıyor.
class CastCommand {
  static const String resume = 'resume';
  static const String pause = 'pause';
  static const String seek = 'seek';
  static const String next = 'next';
  static const String previous = 'previous';
  static const String stop = 'stop';

  static const Set<String> all = {resume, pause, seek, next, previous, stop};
}

/// Yayınla ilgili, kullanıcıya gösterilebilir hata.
class CastException implements Exception {
  const CastException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, Object?>? _decode(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    // Ağda dolaşan her paket JSON değil; bu bir hata değil, "bize ait değil".
    return null;
  }
}
