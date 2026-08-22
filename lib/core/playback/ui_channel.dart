import 'package:flutter/services.dart';

/// Yalnızca aktivite üzerinden yapılabilen işler: ekranı açık tutma ve
/// resim-içinde-resim.
class UiChannel {
  UiChannel._();

  static final UiChannel instance = UiChannel._();

  static const _channel = MethodChannel('akis/ui');

  /// Video izlenirken ekranın kapanmasını engeller. Sesli modda kapatılır ki
  /// telefon normal şekilde uyuyabilsin.
  Future<void> setKeepScreenOn(bool enabled) =>
      _channel.invokeMethod<void>('setKeepScreenOn', {'enabled': enabled});

  /// Videoyu küçük pencereye alır. Cihaz desteklemiyorsa false döner.
  Future<bool> enterPictureInPicture() async =>
      await _channel.invokeMethod<bool>('enterPictureInPicture') ?? false;
}
