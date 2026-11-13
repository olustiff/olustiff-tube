import 'package:flutter/material.dart';

import '../../core/data/settings_store.dart';
import '../../core/i18n/lang.dart';
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
        content: Text(
          error == null
              ? tr('Çalmaya başladı.', 'Playback started.')
              : tr('Olmadı: $error', "Didn't work: $error"),
        ),
      ),
    );
  }

  Future<void> _askForExemption() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Bir izin gerekiyor', 'Permission needed')),
        content: Text(
          tr(
            'Android, arka plandaki uygulamaların kendiliğinden müzik '
                'başlatmasını engelliyor. Bu özelliğin çalışması için '
                'oLusTifF\'i pil kısıtlamasından muaf tutman gerekiyor.\n\n'
                'Açılacak ekranda "İzin ver" demen yeterli.',
            'Android blocks background apps from starting music on their '
                'own. For this feature to work, oLusTifF must be exempt from '
                'battery restrictions.\n\n'
                'Just tap "Allow" on the screen that opens.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Şimdi değil', 'Not now')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('İzin ekranını aç', 'Open permission screen')),
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
      if (!_hasBtPermission) tr('Bluetooth izni', 'Bluetooth permission'),
      if (!_exempt)
        tr('pil kısıtlaması muafiyeti', 'battery restriction exemption'),
    ].join(tr(' ve ', ' and '));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.bluetooth_audio),
          title: Text(
            tr('Bluetooth\'a bağlanınca çal', 'Play on Bluetooth connect'),
          ),
          subtitle: Text(
            tr(
              'Kulaklık/hoparlör bağlanınca son dinlediğin başlar. '
                  'Uygulamayı açmaz, sadece müziği başlatır.',
              'When headphones/a speaker connect, your last track resumes. '
                  "It doesn't open the app, it just starts the music.",
            ),
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
              label: Text(tr('Şimdi dene', 'Try now')),
            ),
          ),
        if (needsPermission)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: Text(tr('İzin eksik', 'Permission missing')),
                subtitle: Text(
                  tr(
                    '$missing gerekiyor. Bunlar olmadan Android '
                        'müziği başlatmıyor.',
                    'Needs $missing. Without it, Android '
                        "won't start the music.",
                  ),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    if (!_hasBtPermission) {
                      await UiChannel.instance.requestBluetoothPermission();
                      await _refresh();
                    }
                    if (mounted && !_exempt) await _askForExemption();
                  },
                  child: Text(tr('İzin ver', 'Allow')),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
