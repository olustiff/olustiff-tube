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
    if (mounted) setState(() => _exempt = exempt);
  }

  Future<void> _toggle(bool value) async {
    final settings = SettingsStore.instance;
    await settings.setBluetoothAutoPlay(value);
    await PlaybackClient.shared.setBluetoothAutoPlay(value);

    if (value && !_exempt && mounted) {
      await _askForExemption();
    }
    if (mounted) setState(() {});
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
    final needsPermission = enabled && !_exempt;

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
        if (needsPermission)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('İzin verilmedi'),
                subtitle: const Text(
                  'Bu izin olmadan Android müziği başlatmıyor.',
                ),
                trailing: TextButton(
                  onPressed: _askForExemption,
                  child: const Text('İzin ver'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
