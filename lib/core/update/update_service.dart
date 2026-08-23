import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Yayınlanmış bir sürüm.
class AppRelease {
  final String version;
  final String notes;
  final String apkUrl;
  final int sizeBytes;

  const AppRelease({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.sizeBytes,
  });

  String get sizeLabel => '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Uygulama içi güncelleme.
///
/// Sürümler GitHub Releases üzerinden yayınlanır: her yeni sürüm için bir
/// release oluşturup APK'yı ona eklemek yeterli. Uygulama son release'i
/// sorar, sürümü karşılaştırır, APK'yı indirir ve kurulumu başlatır.
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// APK indirme ve kurulum native tarafta yapılır (Android paket yükleyici).
  static const _channel = MethodChannel('akis/update');
  static const _progressChannel = EventChannel('akis/update_progress');

  static const _repo = 'olustiff/youtube';

  String _currentVersion = '';
  AppRelease? _available;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  String get currentVersion => _currentVersion;
  AppRelease? get available => _available;
  bool get isChecking => _checking;
  bool get isDownloading => _downloading;
  double get progress => _progress;
  String? get error => _error;

  Future<void> load() async {
    final info = await PackageInfo.fromPlatform();
    _currentVersion = info.version;

    _progressChannel.receiveBroadcastStream().listen((event) {
      final map = event as Map<Object?, Object?>;
      _progress = (map['progress'] as num?)?.toDouble() ?? 0;
      notifyListeners();
    });

    notifyListeners();
  }

  /// Yeni sürüm var mı diye bakar. Sonuç [available]'da tutulur.
  Future<AppRelease?> check() async {
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
        headers: const {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode == 404) {
        // Henüz hiç sürüm yayınlanmamış — hata değil.
        _available = null;
        return null;
      }
      if (response.statusCode != 200) {
        throw Exception('GitHub yanıtı: ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').replaceFirst('v', '');
      final assets = (json['assets'] as List<dynamic>? ?? []);
      final apk = assets.cast<Map<String, dynamic>>().firstWhere(
            (a) => (a['name'] as String? ?? '').endsWith('.apk'),
            orElse: () => <String, dynamic>{},
          );

      if (tag.isEmpty || apk.isEmpty) {
        _available = null;
        return null;
      }

      final release = AppRelease(
        version: tag,
        notes: json['body'] as String? ?? '',
        apkUrl: apk['browser_download_url'] as String,
        sizeBytes: (apk['size'] as num?)?.toInt() ?? 0,
      );

      _available = isNewer(release.version, _currentVersion) ? release : null;
      return _available;
    } catch (e) {
      _error = '$e';
      return null;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// APK'yı indirir ve Android'in kurulum ekranını açar.
  Future<void> downloadAndInstall(AppRelease release) async {
    _downloading = true;
    _progress = 0;
    _error = null;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('downloadAndInstall', {
        'url': release.apkUrl,
        'version': release.version,
      });
    } on PlatformException catch (e) {
      _error = e.message ?? 'Güncelleme kurulamadı';
    } finally {
      _downloading = false;
      notifyListeners();
    }
  }
}

/// "1.2.10" > "1.2.9" gibi karşılaştırma.
///
/// Metin karşılaştırması yanlış sonuç verir ("1.10" < "1.9"), bu yüzden
/// parçalar sayıya çevrilip tek tek karşılaştırılır.
bool isNewer(String candidate, String current) {
  List<int> parse(String v) => v
      .split(RegExp(r'[.+-]'))
      .map((p) => int.tryParse(p) ?? 0)
      .toList();

  final a = parse(candidate);
  final b = parse(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
