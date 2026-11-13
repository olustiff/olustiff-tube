import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/lang.dart';
import '../playback/playback_client.dart';

/// Kullanıcının oynatma tercihleri.
class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static final SettingsStore instance = SettingsStore._();

  static const _kMaxHeight = 'max_height';
  static const _kSpeed = 'playback_speed';
  static const _kAutoplay = 'autoplay';
  static const _kMusicAsAudio = 'music_as_audio';
  static const _kLastAudioOnly = 'last_audio_only';
  static const _kBluetoothAutoPlay = 'bluetooth_autoplay';
  static const _kLoudnessBoost = 'loudness_boost';

  /// Seçilebilir kalite tavanları. `null` = "Otomatik": çözünürlüğü ağ hızına
  /// göre oynatıcı seçer.
  static const qualityOptions = <int?>[null, 2160, 1440, 1080, 720, 480, 360];
  static const speedOptions = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  /// Ses yükseltme kademeleri (milibel; 100 mB = 1 dB).
  ///
  /// Üst kademeler bilerek "önerilmeyen" bölgede: Android'in efekti taşan
  /// sinyali sıkıştırdığı için yüksek kazançta ses nefes alıp vermeye başlıyor
  /// (bkz. LoudnessBoost). Seçenek yine de duruyor — kısık sesten şikâyet eden
  /// kullanıcı bozulmayı göze alabilir.
  static const loudnessOptions = <int>[0, 200, 400, 700, 900];

  static const _defaultLoudness = 400;

  SharedPreferences? _prefs;

  /// Varsayılan "Otomatik": sabit bir çözünürlük, ağ yavaşladığında kalite
  /// düşürmek yerine videoyu takılmaya bırakıyordu.
  int? _maxHeight;
  double _speed = 1.0;
  bool _autoplay = true;
  int _loudnessBoost = _defaultLoudness;

  /// Müzik olarak tespit edilen içerikler sesli modda mı açılsın.
  /// Kapatılırsa her şey video modunda başlar.
  bool _musicAsAudio = true;

  /// Kullanıcının oynatıcıda ELLE seçtiği son mod (true = sesli); hiç
  /// seçmediyse null.
  ///
  /// Doluysa yeni açılan her şey bu modda başlar. Önceden her videoda mod
  /// içeriğin türüne göre yeniden tahmin ediliyordu ve aynı sanatçının bir
  /// videosu "Music", ötekisi "Entertainment" kategorisinde olabildiği için
  /// kullanıcı bunu "uygulama kendiliğinden mod değiştiriyor" diye yaşadı.
  bool? _lastAudioOnly;
  bool? get lastAudioOnly => _lastAudioOnly;

  Future<void> setLastAudioOnly(bool value) async {
    _lastAudioOnly = value;
    await _prefs?.setBool(_kLastAudioOnly, value);
  }

  /// Bluetooth ses aygıtı bağlanınca son çalınan otomatik başlasın mı.
  bool _bluetoothAutoPlay = false;

  int? get maxHeight => _maxHeight;
  double get speed => _speed;
  bool get autoplay => _autoplay;
  bool get musicAsAudio => _musicAsAudio;
  bool get bluetoothAutoPlay => _bluetoothAutoPlay;

  /// Ses yükseltme kazancı (milibel). 0 = kapalı.
  int get loudnessBoost => _loudnessBoost;

  /// Ayar ekranında gösterilen etiket.
  String get loudnessLabel => switch (_loudnessBoost) {
        0 => tr('Kapalı', 'Off'),
        <= 200 => tr('Az (+2 dB)', 'Low (+2 dB)'),
        <= 400 => tr('Orta (+4 dB)', 'Medium (+4 dB)'),
        <= 700 => tr('Yüksek (+7 dB)', 'High (+7 dB)'),
        _ => tr('En yüksek (+9 dB)', 'Maximum (+9 dB)'),
      };

  String get qualityLabel =>
      _maxHeight == null ? tr('Otomatik', 'Auto') : '${_maxHeight}p';

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    // -1, "Otomatik" için saklanan değer (SharedPreferences null tutamaz).
    final stored = prefs.getInt(_kMaxHeight);
    _maxHeight = (stored == null || stored < 0) ? null : stored;
    await _syncQualityToNative();
    _speed = prefs.getDouble(_kSpeed) ?? 1.0;
    _autoplay = prefs.getBool(_kAutoplay) ?? true;
    _musicAsAudio = prefs.getBool(_kMusicAsAudio) ?? true;
    _lastAudioOnly = prefs.getBool(_kLastAudioOnly);
    _bluetoothAutoPlay = prefs.getBool(_kBluetoothAutoPlay) ?? false;
    _loudnessBoost = prefs.getInt(_kLoudnessBoost) ?? _defaultLoudness;
    await _syncLoudnessToNative();
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

  Future<void> setLoudnessBoost(int millibels) async {
    _loudnessBoost = millibels;
    await _prefs?.setInt(_kLoudnessBoost, millibels);
    await _syncLoudnessToNative();
    notifyListeners();
  }

  /// Ses efekti native tarafta yaşıyor; ayar oraya bildirilmezse hiçbir şey
  /// değişmez. Kanal yoksa (birim testleri) sessizce geçilir.
  Future<void> _syncLoudnessToNative() async {
    try {
      await PlaybackClient.shared.setLoudnessBoost(_loudnessBoost);
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
    // Ayarı bilerek değiştiren kullanıcı onun uygulanmasını bekliyor; elle
    // seçilmiş son mod onu ezmesin.
    _lastAudioOnly = null;
    await _prefs?.remove(_kLastAudioOnly);
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
