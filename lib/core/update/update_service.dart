import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _channel = MethodChannel('olustiff/update');
  static const _progressChannel = EventChannel('olustiff/update_progress');

  static const _repo = 'olustiff/youtube';

  /// "Daha sonra" denen sürüm. Açılışta aynı sürüm için tekrar tekrar
  /// sorulması rahatsız edici olurdu; kullanıcı isterse ayarlardan yine
  /// kurabilir, bir SONRAKİ sürüm çıkınca yeniden sorulur.
  static const _postponedKey = 'update_postponed_version';

  String _currentVersion = '';
  String? _postponedVersion;
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

  /// Bu sürüm için açılışta sormaya devam edilmeli mi.
  bool isPostponed(String version) => _postponedVersion == version;

  /// Kullanıcı "daha sonra" dedi: bu sürüm açılışta bir daha sorulmaz.
  Future<void> postpone(String version) async {
    _postponedVersion = version;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_postponedKey, version);
    notifyListeners();
  }

  Future<void> load() async {
    final info = await PackageInfo.fromPlatform();
    _currentVersion = info.version;

    final prefs = await SharedPreferences.getInstance();
    _postponedVersion = prefs.getString(_postponedKey);

    _progressChannel.receiveBroadcastStream().listen((event) {
      final map = event as Map<Object?, Object?>;
      _progress = (map['progress'] as num?)?.toDouble() ?? 0;
      notifyListeners();
    });

    notifyListeners();
  }

  /// Cihazın işlemci mimarisi ('arm64' | 'arm32' | 'x64'). Bilinemezse null.
  Future<String?> _deviceAbi() async {
    try {
      return await _channel.invokeMethod<String>('deviceAbi');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Yeni sürüm var mı diye bakar. Sonuç [available]'da tutulur.
  Future<AppRelease?> check() async {
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      // Süre sınırı şart: zayıf ağda istek asılı kalınca "kontrol ediliyor"
      // sonsuza dek dönüyor ve tekrar denemek mümkün olmuyordu.
      final response = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 404) {
        // Depo erişilemiyor ya da hiç sürüm yayınlanmamış. "En güncelsin"
        // demek yanıltıcı olurdu — kullanıcı güncelleme gelmediğini
        // sanmasın, kaynağın hazır olmadığını bilsin.
        _error = 'Sürüm kaynağına ulaşılamadı. Depo herkese açık olmalı ve '
            'en az bir sürüm yayınlanmış olmalı.';
        _available = null;
        return null;
      }
      if (response.statusCode != 200) {
        throw Exception('GitHub yanıtı: ${response.statusCode}');
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').replaceFirst('v', '');
      final assets = (json['assets'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final apk = pickApkAsset(assets, await _deviceAbi());

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
        // Native taraf, yarım inmiş dosyayı "hazır" sanmasın diye boyutu
        // doğruluyor: eksiksiz inmişse yeniden indirilmiyor.
        'sizeBytes': release.sizeBytes,
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

/// Cihaza uyan sürüm dosyasını seçer.
///
/// Her mimari ayrı yayınlanıyor (arm64 ~21 MB), hepsini taşıyan ortak dosya
/// ise ~53 MB. Uygun olanı bulamazsak ortak dosyaya düşülür — yanlış
/// mimarili bir APK kurdurmaktansa fazladan indirmek yeğdir.
Map<String, dynamic> pickApkAsset(
  List<Map<String, dynamic>> assets,
  String? abi,
) {
  String nameOf(Map<String, dynamic> a) => a['name'] as String? ?? '';
  final apks = assets.where((a) => nameOf(a).endsWith('.apk')).toList();
  if (apks.isEmpty) return <String, dynamic>{};

  if (abi != null) {
    for (final apk in apks) {
      if (nameOf(apk).contains('-$abi.')) return apk;
    }
  }

  for (final apk in apks) {
    if (!RegExp(r'-(arm64|arm32|x64)\.').hasMatch(nameOf(apk))) return apk;
  }
  return apks.first;
}
