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
  final String path;
  final int sizeBytes;

  /// Kbit/sn cinsinden kodlama kalitesi.
  final int bitrate;

  const DownloadedItem({
    required this.videoId,
    required this.title,
    required this.uploaderName,
    required this.durationSeconds,
    required this.path,
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
        sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
        bitrate: (map['bitrate'] as num?)?.toInt() ?? 320,
      );

  Map<String, Object?> toJson() => {
        'videoId': videoId,
        'title': title,
        'uploaderName': uploaderName,
        'durationSeconds': durationSeconds,
        'path': path,
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

  static const _channel = MethodChannel('akis/downloads');
  static const _progressChannel = EventChannel('akis/downloads_progress');
  static const _kItems = 'downloads';

  /// Seçilebilir MP3 kaliteleri (kbit/sn).
  static const bitrateOptions = <int>[320, 256, 192, 128];

  SharedPreferences? _prefs;
  List<DownloadedItem> _items = [];

  /// Süren indirmelerin ilerlemesi (0..1) — arayüz yüzde gösterir.
  final Map<String, double> _progress = {};

  List<DownloadedItem> get items => List.unmodifiable(_items);
  bool isDownloading(String videoId) => _progress.containsKey(videoId);
  double progressOf(String videoId) => _progress[videoId] ?? 0;

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

    // Diskte olmayan kayıtları ele: kullanıcı dosyayı silmiş olabilir.
    final onDisk = await _listFiles();
    _items = _items.where((i) => onDisk.contains(i.path)).toList();
    await _save();
  }

  Future<Set<String>> _listFiles() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('list') ?? [];
      return raw
          .map((e) => (e as Map<Object?, Object?>)['path'] as String?)
          .whereType<String>()
          .toSet();
    } on PlatformException {
      return {};
    }
  }

  /// Videonun sesini MP3 olarak indirir.
  Future<DownloadedItem> download(String videoId, {int bitrate = 320}) async {
    _progress[videoId] = 0;
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
      notifyListeners();
    }
  }

  Future<void> delete(DownloadedItem item) async {
    await _channel.invokeMethod<bool>('delete', {'path': item.path});
    _items.remove(item);
    await _save();
  }

  Future<void> _save() async {
    await _prefs?.setString(
      _kItems,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }
}
