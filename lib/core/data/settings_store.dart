import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../playback/playback_client.dart';

/// Kullanıcının oynatma tercihleri.
class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static final SettingsStore instance = SettingsStore._();

  static const _kMaxHeight = 'max_height';
  static const _kSpeed = 'playback_speed';
  static const _kAutoplay = 'autoplay';
  static const _kMusicAsAudio = 'music_as_audio';
  static const _kBluetoothAutoPlay = 'bluetooth_autoplay';

  /// Seçilebilir kalite tavanları. `null` = "Otomatik": çözünürlüğü ağ hızına
  /// göre oynatıcı seçer.
  static const qualityOptions = <int?>[null, 2160, 1440, 1080, 720, 480, 360];
  static const speedOptions = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  SharedPreferences? _prefs;

  /// Varsayılan "Otomatik": sabit bir çözünürlük, ağ yavaşladığında kalite
  /// düşürmek yerine videoyu takılmaya bırakıyordu.
  int? _maxHeight;
  double _speed = 1.0;
  bool _autoplay = true;

  /// Müzik olarak tespit edilen içerikler sesli modda mı açılsın.
  /// Kapatılırsa her şey video modunda başlar.
  bool _musicAsAudio = true;

  /// Bluetooth ses aygıtı bağlanınca son çalınan otomatik başlasın mı.
  bool _bluetoothAutoPlay = false;

  int? get maxHeight => _maxHeight;
  double get speed => _speed;
  bool get autoplay => _autoplay;
  bool get musicAsAudio => _musicAsAudio;
  bool get bluetoothAutoPlay => _bluetoothAutoPlay;

  String get qualityLabel => _maxHeight == null ? 'Otomatik' : '${_maxHeight}p';

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    // -1, "Otomatik" için saklanan değer (SharedPreferences null tutamaz).
    final stored = prefs.getInt(_kMaxHeight);
    _maxHeight = (stored == null || stored < 0) ? null : stored;
    await _syncQualityToNative();
    _speed = prefs.getDouble(_kSpeed) ?? 1.0;
    _autoplay = prefs.getBool(_kAutoplay) ?? true;
    _musicAsAudio = prefs.getBool(_kMusicAsAudio) ?? true;
    _bluetoothAutoPlay = prefs.getBool(_kBluetoothAutoPlay) ?? false;
    notifyListeners();
  }

  Future<void> setMaxHeight(int? value) async {
    _maxHeight = value;
    await _prefs?.setInt(_kMaxHeight, value ?? -1);
    await _syncQualityToNative();
    notifyListeners();
  }

  /// Kalite tercihi native tarafta da bilinmeli: kuyrukta sıradakine geçiş
  /// orada yapılıyor (ekran kapalıyken de ilerlemeli) ve o an kaynağı Dart
  /// değil native seçiyor.
  ///
  /// Kanal yoksa (birim testleri) sessizce geçilir — ayar deposu oynatıcıya
  /// bağımlı olmamalı.
  Future<void> _syncQualityToNative() async {
    try {
      await PlaybackClient.shared.setMaxHeight(_maxHeight);
    } on MissingPluginException {
      // Yoksay.
    } on PlatformException {
      // Yoksay.
    }
  }

  Future<void> setSpeed(double value) async {
    _speed = value;
    await _prefs?.setDouble(_kSpeed, value);
    notifyListeners();
  }

  Future<void> setMusicAsAudio(bool value) async {
    _musicAsAudio = value;
    await _prefs?.setBool(_kMusicAsAudio, value);
    notifyListeners();
  }

  Future<void> setBluetoothAutoPlay(bool value) async {
    _bluetoothAutoPlay = value;
    await _prefs?.setBool(_kBluetoothAutoPlay, value);
    notifyListeners();
  }

  Future<void> setAutoplay(bool value) async {
    _autoplay = value;
    await _prefs?.setBool(_kAutoplay, value);
    notifyListeners();
  }
}
