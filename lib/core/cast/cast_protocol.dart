/// Telefon ↔ televizyon arasındaki yayın (cast) protokolü.
///
/// Neden hazır bir çözüm değil de kendi protokolümüz — elenen yollar:
///
/// - **Google Cast SDK**: alıcı uygulamanın Cast Developer Console'a (ücretli)
///   kaydını, televizyonun seri numarasının tek tek beyaz listeye eklenmesini
///   ve uygulamanın Play Store'dan kurulmuş olmasını istiyor. Üstüne, cihaz
///   uygulama kimliğini Google'ın sunucusundan çözüyor — yani "buluta bağımlı
///   olmasın" şartını da bozardı.
/// - **DIAL ile televizyonun YouTube uygulamasını açmak**: Android TV /
///   Google TV cihazlar keşfe (SSDP) cevap veriyor ama `/apps/YouTube`
///   isteğine 404 dönüyor; YouTube o cihazlarda DIAL kaydında değil. Bu yol
///   Fire TV / webOS / Tizen'de yaşıyor, bizim televizyonda ölü.
/// - **YouTube Lounge API**: çalışıyor, ama komutların tamamı
///   `youtube.com/api/lounge` üzerinden İNTERNETTEN geçiyor ve resmî değil —
///   hem "sunucu yok" şartına aykırı hem de Google istediği an kesebilir.
///
/// Geriye kalan ve şartların tamamını karşılayan tek yol: iki uçta da BİZİM
/// uygulamamız çalıştığı için kendi protokolümüz. UDP yayınıyla keşif, HTTP
/// ile komut. Kayıt yok, bulut yok, bağımlılık yok.
library;

import 'dart:convert';

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
      'app': ?appVersion,
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
    this.volume,
    this.isMuted = false,
  });

  final String? videoId;
  final String? title;
  final Duration position;
  final Duration? duration;
  final bool isPlaying;

  /// Televizyonun medya ses seviyesi, 0..1 aralığında.
  ///
  /// null = televizyon bildirmedi (eski sürüm ya da ses seviyesi okunamadı);
  /// arayüz o zaman kaydırıcıyı göstermez. 0 ile null AYRI şeyler: 0 "sesi
  /// kısılmış", null "bilmiyoruz".
  final double? volume;
  final bool isMuted;

  Map<String, Object?> toJson() => {
        'videoId': videoId,
        'title': title,
        'positionMs': position.inMilliseconds,
        'durationMs': duration?.inMilliseconds,
        'isPlaying': isPlaying,
        'volume': volume,
        'muted': isMuted,
      };

  CastRemoteState copyWith({
    Duration? position,
    bool? isPlaying,
    double? volume,
    bool? isMuted,
  }) =>
      CastRemoteState(
        videoId: videoId,
        title: title,
        position: position ?? this.position,
        duration: duration,
        isPlaying: isPlaying ?? this.isPlaying,
        volume: volume ?? this.volume,
        isMuted: isMuted ?? this.isMuted,
      );

  static CastRemoteState? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final durationMs = raw['durationMs'];
    final volume = raw['volume'];
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
      volume: volume is num ? volume.toDouble().clamp(0.0, 1.0) : null,
      isMuted: raw['muted'] as bool? ?? false,
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

  /// Mutlak ses seviyesi; `volume` alanıyla 0..1 arasında gelir.
  static const String volume = 'volume';

  /// Bir kademe artır/azalt. Kademe büyüklüğünü televizyon belirler —
  /// telefon cihazın kaç kademesi olduğunu bilmek zorunda kalmasın.
  static const String volumeUp = 'volumeUp';
  static const String volumeDown = 'volumeDown';

  /// Sessize alma; aç/kapa olarak çalışır.
  static const String mute = 'mute';

  static const Set<String> all = {
    resume,
    pause,
    seek,
    next,
    previous,
    stop,
    volume,
    volumeUp,
    volumeDown,
    mute,
  };
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
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    // Ağda dolaşan her paket JSON değil; bu bir hata değil, "bize ait değil".
    return null;
  }
}
