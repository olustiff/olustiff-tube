import 'package:flutter/material.dart';

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
        title: const Text('Bir izin gerekiyor'),
        content: const Text(
          'Android, arka plandaki uygulamaların kendiliğinden ekran '
          'açmasını engelliyor. Telefondan gönderilen videonun burada '
          'kendiliğinden açılabilmesi için oLusTifF\'e "diğer uygulamaların '
          'üzerinde göster" izni gerekiyor.\n\n'
          'Açılacak ekranda oLusTifF\'i bulup izni açman yeterli.',
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
      await UiChannel.instance.requestDrawOverlays();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_canOpen) {
      return const ListTile(
        leading: Icon(Icons.cast_connected),
        title: Text('Telefondan yayın'),
        subtitle: Text(
          'Hazır. Uygulama kapalı olsa bile telefondan gönderilen video '
          'burada kendiliğinden açılır.',
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.warning_amber),
          title: const Text('Telefondan yayın yarım çalışıyor'),
          subtitle: const Text(
            'Televizyon telefonda listede görünür, ama uygulama kapalıyken '
            'gelen video kendiliğinden açılmaz. İzni verirsen uygulamayı '
            'elle açman gerekmez.',
          ),
          trailing: TextButton(onPressed: _ask, child: const Text('İzin ver')),
        ),
      ),
    );
  }
}
