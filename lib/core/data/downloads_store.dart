import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// İndirilmiş bir MP3.
class DownloadedItem {
  final String videoId;
  final String title;
  final String? uploaderName;
  final int durationSeconds;

  /// Dosya YOLU DEĞİL: MediaStore kaydının `content://` adresi.
  ///
  /// MP3'ler artık ortak `Music/oLusTifF` klasöründe duruyor ve oraya yalnızca
  /// MediaStore üzerinden erişiliyor; dosya sisteminde tutunabileceğimiz bir
  /// yol yok. Alan adı `path` olarak korundu — oynatma ve silme çağrıları bu
  /// değeri olduğu gibi native tarafa geri veriyor.
  final String path;

  /// Müzik klasöründeki gerçek dosya adı. Aynı şarkı ikinci kez indirilirse
  /// MediaStore üzerine yazmaz, "ad (1).mp3" diye çoğaltır; gerçek ad budur.
  final String fileName;

  final int sizeBytes;

  /// Kbit/sn cinsinden kodlama kalitesi.
  final int bitrate;

  const DownloadedItem({
    required this.videoId,
    required this.title,
    required this.uploaderName,
    required this.durationSeconds,
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.bitrate,
  });

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(1)} MB';
  }

  factory DownloadedItem.fromMap(Map<Object?, Object?> map) => DownloadedItem(
        videoId: map['videoId'] as String? ?? '',
        title: map['title'] as String? ?? '',
        uploaderName: map['uploaderName'] as String?,
        durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
        path: map['path'] as String? ?? '',
        fileName: map['fileName'] as String? ?? '',
        sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
        bitrate: (map['bitrate'] as num?)?.toInt() ?? 320,
      );

  Map<String, Object?> toJson() => {
        'videoId': videoId,
        'title': title,
        'uploaderName': uploaderName,
        'durationSeconds': durationSeconds,
        'path': path,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'bitrate': bitrate,
      };

  factory DownloadedItem.fromJson(Map<String, dynamic> json) =>
      DownloadedItem.fromMap(json);
}

/// İndirmeleri yürütür ve kayıtlarını tutar.
///
/// Dosyalar native tarafta oluşturuluyor; burada yalnızca listeyi ve
/// "hangi indirme sürüyor" bilgisini tutuyoruz.
class DownloadsStore extends ChangeNotifier {
  DownloadsStore._();

  static final DownloadsStore instance = DownloadsStore._();

  static const _channel = MethodChannel('olustiff/downloads');
  static const _progressChannel = EventChannel('olustiff/downloads_progress');
  static const _kItems = 'downloads';

  /// Seçilebilir MP3 kaliteleri (kbit/sn).
  static const bitrateOptions = <int>[320, 256, 192, 128];

  SharedPreferences? _prefs;
  List<DownloadedItem> _items = [];

  /// Süren indirmelerin ilerlemesi (0..1) — arayüz yüzde gösterir.
  final Map<String, double> _progress = {};

  /// Süren indirmelerin başlıkları. Arayüzün "ne iniyor" diye başka
  /// kaynaklardan tahmin yürütmesine gerek kalmasın diye burada tutulur.
  final Map<String, String> _titles = {};

  List<DownloadedItem> get items => List.unmodifiable(_items);
  bool isDownloading(String videoId) => _progress.containsKey(videoId);
  double progressOf(String videoId) => _progress[videoId] ?? 0;

  /// Şu an inen dosyalar: (videoId, başlık, ilerleme).
  List<({String videoId, String title, double progress})> get activeDownloads =>
      _progress.entries
          .map((e) => (
                videoId: e.key,
                title: _titles[e.key] ?? '',
                progress: e.value,
              ))
          .toList(growable: false);

  bool hasDownload(String videoId) =>
      _items.any((i) => i.videoId == videoId);

  Future<void> load() async {
    // Native taraf indirme ilerlemesini buradan bildiriyor.
    _progressChannel.receiveBroadcastStream().listen((event) {
      final map = event as Map<Object?, Object?>;
      final videoId = map['videoId'] as String?;
      final value = (map['progress'] as num?)?.toDouble();
      if (videoId == null || value == null) return;
      _progress[videoId] = value;
      notifyListeners();
    });

    final prefs = _prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(_kItems);
    if (raw != null) {
      final list = jsonDecode(raw) as List<dynamic>;
      _items = list
          .map((e) => DownloadedItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    // Müzik klasöründe artık bulunmayan kayıtları ele: kullanıcı dosyayı
    // telefonunun dosya yöneticisinden silmiş olabilir.
    final onDisk = await _listFiles();
    _items = _items.where((i) => onDisk.contains(i.path)).toList();
    await _save();
  }

  /// Music/oLusTifF klasöründeki MP3'lerin content URI'ları.
  Future<Set<String>> _listFiles() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('list') ?? [];
      return raw
          .map((e) => (e as Map<Object?, Object?>)['uri'] as String?)
          .whereType<String>()
          .toSet();
    } on PlatformException {
      return {};
    }
  }

  /// Videonun sesini MP3 olarak indirir ve ortak Müzik klasörüne kaydeder.
  Future<DownloadedItem> download(
    String videoId, {
    int bitrate = 320,
    String title = '',
  }) async {
    _progress[videoId] = 0;
    _titles[videoId] = title;
    notifyListeners();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'downloadMp3',
        {'videoId': videoId, 'bitrate': bitrate},
      );
      final item = DownloadedItem.fromMap(raw!);
      // Aynı video tekrar indirilirse kaydı tazele.
      _items.removeWhere((i) => i.videoId == videoId);
      _items.insert(0, item);
      await _save();
      return item;
    } finally {
      _progress.remove(videoId);
      _titles.remove(videoId);
      notifyListeners();
    }
  }

  Future<void> delete(DownloadedItem item) async {
    // 'path' bir content URI; native taraf MediaStore kaydını siler.
    await _channel.invokeMethod<bool>('delete', {'path': item.path});
    _items.remove(item);
    await _save();
  }

  /// İndirme klasörünü ("Music/oLusTifF") cihazın dosya uygulamasında açar.
  ///
  /// Klasör açmanın her cihazda çalışan tek bir yolu yok; açılamadıysa hata
  /// fırlatmak yerine `false` döner ki arayüz seçeneği gizleyebilsin.
  Future<bool> openFolder() async {
    try {
      return await _channel.invokeMethod<bool>('openFolder') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _save() async {
    await _prefs?.setString(
      _kItems,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }
}
