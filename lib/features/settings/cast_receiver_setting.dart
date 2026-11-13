import 'package:flutter/material.dart';

import '../../core/i18n/lang.dart';
import '../../core/playback/ui_channel.dart';

/// "Uygulama kapalıyken de yayın al" ayarı — YALNIZCA televizyonda.
///
/// Yayın alıcısı açılıştan beri arka planda çalışıyor, yani telefon
/// televizyonu her zaman bulabiliyor. Ama gelen video için uygulamanın
/// AÇILMASI gerekiyor ve Android 10+ arka plandaki uygulamaların ekran
/// açmasını yasaklıyor.
///
/// Bu yasağın işe yarayan tek istisnası "diğer uygulamaların üzerinde
/// göster" izni. Pil kısıtlaması muafiyeti (Bluetooth özelliğinde kullanılan
/// yol) burada YETMİYOR: ölçüldüğünde sistem yine BAL_BLOCK diyor.
///
/// Kapalıyken özellik yarım çalışır — televizyon listede görünür, video
/// gönderilir ama ekran açılmaz. Bunu gizlemek yerine açıkça söylüyoruz.
class CastReceiverSetting extends StatefulWidget {
  const CastReceiverSetting({super.key});

  @override
  State<CastReceiverSetting> createState() => _CastReceiverSettingState();
}

class _CastReceiverSettingState extends State<CastReceiverSetting>
    with WidgetsBindingObserver {
  bool _canOpen = false;

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
    // Kullanıcı sistem izin ekranından dönünce durum tazelensin.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final canOpen = await UiChannel.instance.canDrawOverlays();
    if (mounted) setState(() => _canOpen = canOpen);
  }

  Future<void> _ask() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Bir izin gerekiyor', 'Permission needed')),
        content: Text(
          tr(
            'Android, arka plandaki uygulamaların kendiliğinden ekran '
                'açmasını engelliyor. Telefondan gönderilen videonun burada '
                'kendiliğinden açılabilmesi için oLusTifF\'e "diğer uygulamaların '
                'üzerinde göster" izni gerekiyor.\n\n'
                'Açılacak ekranda oLusTifF\'i bulup izni açman yeterli.',
            'Android blocks background apps from opening screens on their '
                'own. For videos sent from your phone to open here '
                'automatically, oLusTifF needs the "Display over other apps" '
                'permission.\n\n'
                'Just find oLusTifF on the screen that opens and turn it on.',
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
      await UiChannel.instance.requestDrawOverlays();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_canOpen) {
      return ListTile(
        leading: const Icon(Icons.cast_connected),
        title: Text(tr('Telefondan yayın', 'Cast from phone')),
        subtitle: Text(
          tr(
            'Hazır. Uygulama kapalı olsa bile telefondan gönderilen video '
                'burada kendiliğinden açılır.',
            'Ready. Videos sent from your phone open here automatically, '
                'even when the app is closed.',
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.warning_amber),
          title: Text(tr('Telefondan yayın yarım çalışıyor',
              'Cast from phone only partly works')),
          subtitle: Text(
            tr(
              'Televizyon telefonda listede görünür, ama uygulama kapalıyken '
                  'gelen video kendiliğinden açılmaz. İzni verirsen uygulamayı '
                  'elle açman gerekmez.',
              'The TV shows up in the list on your phone, but videos sent '
                  "while the app is closed won't open by themselves. Grant "
                  "the permission and you won't need to open the app manually.",
            ),
          ),
          trailing: TextButton(
            onPressed: _ask,
            child: Text(tr('İzin ver', 'Allow')),
          ),
        ),
      ),
    );
  }
}
