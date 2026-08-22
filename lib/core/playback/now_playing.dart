import 'package:flutter/foundation.dart';

import '../extraction/models.dart';

/// Şu an çalan içeriğin uygulama genelindeki tek kaydı.
///
/// Native player zaten arka planda çalmaya devam ettiği için Dart tarafının da
/// "ne çalıyor ve hangi modda" bilgisini hatırlaması gerekir. Aksi hâlde
/// kullanıcı oynatma ekranından çıkıp geri döndüğünde uygulama medyayı baştan
/// yükler ve seçilen mod kaybolurdu.
class NowPlaying extends ChangeNotifier {
  NowPlaying._();

  static final NowPlaying instance = NowPlaying._();

  VideoDetails? _details;
  bool _audioOnly = false;
  String? _qualityLabel;

  VideoDetails? get details => _details;
  bool get audioOnly => _audioOnly;
  String? get qualityLabel => _qualityLabel;
  bool get hasMedia => _details != null;

  String? get videoId => _details?.videoId;

  bool isCurrent(String videoId) => _details?.videoId == videoId;

  void start(VideoDetails details, {required bool audioOnly, String? quality}) {
    _details = details;
    _audioOnly = audioOnly;
    _qualityLabel = quality;
    notifyListeners();
  }

  /// Yalnızca kullanıcının açık isteğiyle çağrılır — otomatik mod değişimi yok.
  void updateMode({required bool audioOnly, String? quality}) {
    _audioOnly = audioOnly;
    _qualityLabel = quality;
    notifyListeners();
  }

  void clear() {
    _details = null;
    _qualityLabel = null;
    notifyListeners();
  }
}
