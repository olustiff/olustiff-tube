import 'package:flutter/material.dart';

import '../../core/data/settings_store.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/ui_channel.dart';

/// "Bluetooth'a bağlanınca çal" ayarı.
///
/// Android 12+ arka plandan servis başlatmayı yasaklar ve Bluetooth yayını
/// bunun istisnası DEĞİLDİR. Tek geçerli yol uygulamanın pil
/// optimizasyonundan muaf olması; bu yüzden ayar açılırken izin istenir.
class BluetoothSetting extends StatefulWidget {
  const BluetoothSetting({super.key});

  @override
  State<BluetoothSetting> createState() => _BluetoothSettingState();
}

class _BluetoothSettingState extends State<BluetoothSetting>
    with WidgetsBindingObserver {
  bool _exempt = false;
  bool _hasBtPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Kullanıcı sistem ayarından dönünce durumu tazele.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final exempt = await UiChannel.instance.isBatteryOptimizationIgnored();
    final bt = await UiChannel.instance.hasBluetoothPermission();
    if (mounted) {
      setState(() {
        _exempt = exempt;
        _hasBtPermission = bt;
      });
    }
  }

  Future<void> _toggle(bool value) async {
    final settings = SettingsStore.instance;
    await settings.setBluetoothAutoPlay(value);
    await PlaybackClient.shared.setBluetoothAutoPlay(value);

    if (value) {
      // İki izin de şart: bluetooth izni olmadan yayın hiç gelmez, pil
      // muafiyeti olmadan Android arka planda çalmayı engeller.
      if (!_hasBtPermission) {
        await UiChannel.instance.requestBluetoothPermission();
        await _refresh();
      }
      if (mounted && !_exempt) await _askForExemption();
    }
    if (mounted) setState(() {});
  }

  /// Kulaklık bağlamadan otomatik çalmayı dener; sonucu kullanıcıya söyler.
  Future<void> _test() async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await PlaybackClient.shared.testBluetoothAutoPlay();
    messenger.showSnackBar(
      SnackBar(
        content: Text(error == null ? 'Çalmaya başladı.' : 'Olmadı: $error'),
      ),
    );
  }

  Future<void> _askForExemption() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bir izin gerekiyor'),
        content: const Text(
          'Android, arka plandaki uygulamaların kendiliğinden müzik '
          'başlatmasını engelliyor. Bu özelliğin çalışması için '
          'oLusTifF\'i pil kısıtlamasından muaf tutman gerekiyor.\n\n'
          'Açılacak ekranda "İzin ver" demen yeterli.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Şimdi değil'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('İzin ekranını aç'),
          ),
        ],
      ),
    );

    if (accepted == true) {
      await UiChannel.instance.requestIgnoreBatteryOptimization();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;
    final enabled = settings.bluetoothAutoPlay;
    // İzin yoksa özellik açık görünse de çalışmaz; bunu gizlemek yerine
    // açıkça söylüyoruz.
    final needsPermission = enabled && (!_exempt || !_hasBtPermission);
    final missing = [
      if (!_hasBtPermission) 'Bluetooth izni',
      if (!_exempt) 'pil kısıtlaması muafiyeti',
    ].join(' ve ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.bluetooth_audio),
          title: const Text('Bluetooth\'a bağlanınca çal'),
          subtitle: const Text(
            'Kulaklık/hoparlör bağlanınca son dinlediğin başlar. '
            'Uygulamayı açmaz, sadece müziği başlatır.',
          ),
          value: enabled,
          onChanged: _toggle,
        ),
        if (enabled && !needsPermission)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: OutlinedButton.icon(
              onPressed: _test,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Şimdi dene'),
            ),
          ),
        if (needsPermission)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('İzin eksik'),
                subtitle: Text(
                  '$missing gerekiyor. Bunlar olmadan Android '
                  'müziği başlatmıyor.',
                ),
                trailing: TextButton(
                  onPressed: () async {
                    if (!_hasBtPermission) {
                      await UiChannel.instance.requestBluetoothPermission();
                      await _refresh();
                    }
                    if (mounted && !_exempt) await _askForExemption();
                  },
                  child: const Text('İzin ver'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
