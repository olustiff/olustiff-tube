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
      } else if (call.method == 'castVolumeKey') {
        onCastVolumeKey?.call(call.arguments as String? ?? '');
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

  /// Fiziksel ses tuşuna basıldığında çağrılır: 'up' ya da 'down'.
  ///
  /// Yalnızca [setCastVolumeKeys] açıkken tetiklenir. Yayını yöneten taraf
  /// (CastController) bunu doldurup boşaltıyor.
  void Function(String direction)? onCastVolumeKey;

  /// Ses tuşlarını televizyona yönlendirmeyi açar/kapatır.
  ///
  /// Açıkken telefonun KENDİ sesi değişmez: ses televizyondan geliyor,
  /// telefonunkini kısmak kullanıcıyı şaşırtırdı.
  Future<void> setCastVolumeKeys(bool enabled) =>
      _channel.invokeMethod<void>('setCastVolumeKeys', {'enabled': enabled});

  /// Oynatma tanılama günlüğünü paylaşılabilir tek dosyada toplar; yolunu
  /// döndürür. Henüz kayıt yoksa null.
  Future<String?> diagnosticsFile() =>
      _channel.invokeMethod<String>('diagnosticsFile');

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

  /// Televizyonda yayın alıcısı, uygulama kapalıyken de uygulamayı
  /// açabiliyor mu.
  ///
  /// Android 10+ arka plandaki uygulamaların ekran açmasını yasaklıyor.
  /// "Diğer uygulamaların üzerinde göster" izni bu yasağın istisnası —
  /// pil muafiyeti YETMİYOR (ölçüldü: sistem BAL_BLOCK diyor).
  Future<bool> canDrawOverlays() async {
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } catch (_) {
      // Eski kurulumda bu yöntem yok; özelliği yokmuş gibi göster.
      return false;
    }
  }

  /// İzin ekranını açar.
  Future<void> requestDrawOverlays() =>
      _channel.invokeMethod<void>('requestDrawOverlays');

  /// Cihaz televizyon mu.
  ///
  /// Televizyonda kumandayla (D-pad) geziliyor: odaklanan öğe belirgin bir
  /// çerçeveyle işaretlenmeli, dokunmaya özel hareketler ise anlamsız.
  Future<bool> isTelevision() async =>
      await _channel.invokeMethod<bool>('isTelevision') ?? false;

  /// Cihazda sistem ses tanıma var mı.
  ///
  /// Yoksa arayüz mikrofon düğmesini hiç göstermez — basılınca hiçbir şey
  /// olmayan bir düğme, olmayan düğmeden kötüdür.
  Future<bool> isVoiceSearchAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isVoiceSearchAvailable') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Sistemin ses tanıma ekranını açar; anlaşılan metni döndürür.
  ///
  /// Kullanıcı vazgeçerse, hiçbir şey anlaşılmazsa ya da cihaz
  /// desteklemiyorsa null döner: arama kutusu olduğu gibi kalır.
  Future<String?> startVoiceSearch() async {
    try {
      return await _channel.invokeMethod<String>('startVoiceSearch');
    } catch (_) {
      return null;
    }
  }

  /// Videoyu küçük pencereye alır. Cihaz desteklemiyorsa false döner.
  Future<bool> enterPictureInPicture() async =>
      await _channel.invokeMethod<bool>('enterPictureInPicture') ?? false;
}
