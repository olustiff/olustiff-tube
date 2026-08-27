import 'package:flutter/material.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/cast/cast_protocol.dart';
import '../../core/playback/playback_coordinator.dart';

/// "TV'ye gönder" düğmesi.
///
/// Cihaz araması BASILDIĞINDA yapılıyor, açılışta değil: her oynatma
/// ekranında ağa yayın paketi salmak hem gereksiz hem de düğmenin bir süre
/// sonra "belirmesi" kullanıcıya tuhaf geliyor. Düğme her zaman duruyor;
/// televizyon bulunamazsa sebebini anlatan bir mesaj çıkıyor.
class CastButton extends StatelessWidget {
  const CastButton({super.key, required this.positionOf});

  /// Telefonda kalınan yer. Video televizyonda oradan devam etsin diye
  /// basıldığı anda okunuyor.
  final Duration Function() positionOf;

  @override
  Widget build(BuildContext context) {
    final cast = CastController.instance;
    return AnimatedBuilder(
      animation: cast,
      builder: (context, _) => IconButton(
        tooltip: cast.isCasting
            ? '${cast.device!.name} cihazına gönderiliyor'
            : "TV'ye gönder",
        icon: Icon(cast.isCasting ? Icons.cast_connected : Icons.cast),
        color: cast.isCasting ? Theme.of(context).colorScheme.primary : null,
        onPressed: () => showCastPicker(context, position: positionOf()),
      ),
    );
  }
}

/// Televizyon seçme sayfasını açar.
Future<void> showCastPicker(
  BuildContext context, {
  Duration position = Duration.zero,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => _CastPicker(position: position),
  );
}

class _CastPicker extends StatefulWidget {
  const _CastPicker({required this.position});

  final Duration position;

  @override
  State<_CastPicker> createState() => _CastPickerState();
}

class _CastPickerState extends State<_CastPicker> {
  final _cast = CastController.instance;

  List<CastDevice>? _devices;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() => _devices = null);
    final found = await _cast.search();
    if (mounted) setState(() => _devices = found);
  }

  Future<void> _send(CastDevice device) async {
    final details = PlaybackCoordinator.instance.details;
    if (details == null) return;

    setState(() => _sending = true);
    final ok = await _cast.castTo(
      device,
      videoId: details.videoId,
      title: details.title,
      artist: details.uploaderName,
      thumbnailUrl: details.thumbnailUrl,
      position: widget.position,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    Navigator.of(context).pop();
    final message = ok
        ? '${device.name} cihazında açılıyor…'
        : (_cast.lastError ?? 'Gönderilemedi.');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    if (!ok) _cast.clearError();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: const Text("TV'ye gönder"),
            trailing: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Yeniden ara',
                    icon: const Icon(Icons.refresh),
                    onPressed: devices == null ? null : _search,
                  ),
          ),
          if (_cast.isCasting)
            ListTile(
              leading: const Icon(Icons.cast_connected),
              title: Text(_cast.device!.name),
              subtitle: const Text('Şu an bu cihaza gönderiliyor'),
              trailing: TextButton(
                onPressed: () {
                  _cast.disconnect();
                  Navigator.of(context).pop();
                },
                child: const Text('Bağlantıyı kes'),
              ),
            ),
          if (devices == null)
            const ListTile(
              leading: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Televizyon aranıyor…'),
            )
          else if (devices.isEmpty)
            const _NoDevicesFound()
          else
            for (final device in devices)
              ListTile(
                leading: const Icon(Icons.tv),
                title: Text(device.name),
                subtitle: Text(device.host),
                enabled: !_sending,
                onTap: _sending ? null : () => _send(device),
              ),
        ],
      ),
    );
  }
}

/// Hiçbir televizyon bulunamadığında.
///
/// Sessizce boş liste göstermek en sık karşılaşılan iki sebebi (uygulama
/// televizyonda açık değil, ya da ağ cihazların birbirini görmesini
/// engelliyor) gizlerdi.
class _NoDevicesFound extends StatelessWidget {
  const _NoDevicesFound();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tv_off),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'TV bulunamadı',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            '• İki cihaz da AYNI Wi-Fi ağında olmalı.\n'
            '• Televizyonda oLusTifF açık olmalı.\n'
            '• Bazı modemler 2.4 GHz ve 5 GHz ağlarındaki cihazların '
            'birbirini görmesini engeller; ikisini de aynı banda alıp '
            'tekrar deneyin.',
          ),
        ],
      ),
    );
  }
}
