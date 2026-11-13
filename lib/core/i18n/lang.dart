import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../playback/ui_channel.dart';

/// Arayüz dili seçimi.
enum AppLanguage { system, turkish, english }

/// Uygulamanın dili: Türkçe ya da İngilizce.
///
/// ## Neden ARB/gen-l10n değil
///
/// Yalnızca iki dil var ve metinlerin çoğu bağlam (BuildContext) olmayan
/// yerlerde de üretiliyor (oynatma koordinatörü, güncelleme servisi, yayın
/// istemcisi). Metni kullanıldığı yerde iki dilde birden yazmak
/// ([tr] çağrısı) hem okunur kalıyor hem de anahtar dosyası tutmayı
/// gerektirmiyor.
///
/// Varsayılan [AppLanguage.system]: telefon Türkçeyse Türkçe, değilse
/// İngilizce. [load] hiç çağrılmadıysa (testler) Türkçe.
class Lang extends ChangeNotifier {
  Lang._();

  static final Lang instance = Lang._();

  static const _kLanguage = 'app_language';

  SharedPreferences? _prefs;
  AppLanguage _choice = AppLanguage.system;
  bool _english = false;

  AppLanguage get choice => _choice;
  bool get isEnglish => _english;

  /// Arayüzün dil kodu ("tr" / "en").
  String get code => _english ? 'en' : 'tr';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs!.getString(_kLanguage);
    _choice = AppLanguage.values.firstWhere(
      (l) => l.name == saved,
      orElse: () => AppLanguage.system,
    );
    _resolve();
    await _tellNative();
  }

  Future<void> setChoice(AppLanguage choice) async {
    _choice = choice;
    await _prefs?.setString(_kLanguage, choice.name);
    _resolve();
    await _tellNative();
    notifyListeners();
  }

  /// Testler için: dili doğrudan ayarla (kaydetmeden).
  @visibleForTesting
  void debugSetEnglish(bool english) {
    _english = english;
    notifyListeners();
  }

  void _resolve() {
    _english = switch (_choice) {
      AppLanguage.turkish => false,
      AppLanguage.english => true,
      AppLanguage.system =>
        PlatformDispatcher.instance.locale.languageCode != 'tr',
    };
  }

  /// Bildirimler ve hata iletileri Kotlin tarafında üretiliyor; o da aynı
  /// dili kullansın.
  Future<void> _tellNative() async {
    try {
      await UiChannel.instance.setLanguage(code);
    } catch (_) {
      // Testlerde ve native taraf hazır değilken kanal yok; sorun değil.
    }
  }
}

/// Metni arayüz diline göre seçer: `tr('Ayarlar', 'Settings')`.
String tr(String turkish, String english) =>
    Lang.instance.isEnglish ? english : turkish;
