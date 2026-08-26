import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Yalnızca aktivite üzerinden yapılabilen işler: ekranı açık tutma ve
/// resim-içinde-resim.
class UiChannel {
  UiChannel._() {
    // Native taraf küçük pencereye girip çıkıldığını buradan bildiriyor.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') {
        isInPictureInPicture.value = call.arguments as bool? ?? false;
      }
      return null;
    });
  }

  static final UiChannel instance = UiChannel._();

  static const _channel = MethodChannel('olustiff/ui');

  /// Küçük pencerede miyiz.
  ///
  /// Pencerede yalnızca görüntü olmalı: uygulamanın kendi düğmeleri o boyutta
  /// hem okunaksız hem de gereksiz. Oynat/duraklat'ı sistem kendi düğmesiyle
  /// veriyor.
  final ValueNotifier<bool> isInPictureInPicture = ValueNotifier(false);

  /// Video izlenirken ekranın kapanmasını engeller. Sesli modda kapatılır ki
  /// telefon normal şekilde uyuyabilsin.
  Future<void> setKeepScreenOn(bool enabled) =>
      _channel.invokeMethod<void>('setKeepScreenOn', {'enabled': enabled});

  /// Bluetooth izni verilmiş mi.
  ///
  /// Android 12+ bu izni çalışma anında ister; verilmezse bluetooth bağlantı
  /// yayınları uygulamaya hiç ulaşmaz ve otomatik çalma sessizce çalışmaz.
  Future<bool> hasBluetoothPermission() async =>
      await _channel.invokeMethod<bool>('hasBluetoothPermission') ?? false;

  /// Bluetooth iznini ister; sistem onay penceresini açar.
  Future<void> requestBluetoothPermission() =>
      _channel.invokeMethod<void>('requestBluetoothPermission');

  /// Uygulama pil optimizasyonundan muaf mı.
  ///
  /// Bluetooth bağlanınca müziği arka planda başlatmak yalnızca muaf
  /// uygulamalara izinli (Android 12+).
  Future<bool> isBatteryOptimizationIgnored() async =>
      await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored') ??
      false;

  /// Muafiyet iznini ister; sistem onay ekranını açar.
  Future<void> requestIgnoreBatteryOptimization() =>
      _channel.invokeMethod<void>('requestIgnoreBatteryOptimization');

  /// Cihaz televizyon mu.
  ///
  /// Televizyonda kumandayla (D-pad) geziliyor: odaklanan öğe belirgin bir
  /// çerçeveyle işaretlenmeli, dokunmaya özel hareketler ise anlamsız.
  Future<bool> isTelevision() async =>
      await _channel.invokeMethod<bool>('isTelevision') ?? false;

  /// Videoyu küçük pencereye alır. Cihaz desteklemiyorsa false döner.
  Future<bool> enterPictureInPicture() async =>
      await _channel.invokeMethod<bool>('enterPictureInPicture') ?? false;
}
