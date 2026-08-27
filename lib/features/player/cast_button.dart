import 'package:flutter/material.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/cast/cast_protocol.dart';
import '../../core/cast/youtube_cast_controller.dart';
import '../../core/cast/youtube_cast_protocol.dart';
import '../../core/playback/playback_coordinator.dart';
import 'cast_disconnect.dart';

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
    final youtube = YouTubeCastController.instance;
    // İki yayın yolu da aynı düğmeyi besliyor: kullanıcı için ikisi de
    // "televizyona gönderiyorum" demek.
    return AnimatedBuilder(
      animation: Listenable.merge([cast, youtube]),
      builder: (context, _) {
        final active = cast.isCasting || youtube.isCasting;
        final name = cast.device?.name ?? youtube.device?.name;
        return IconButton(
          tooltip: active ? '$name cihazına gönderiliyor' : "TV'ye gönder",
          icon: Icon(active ? Icons.cast_connected : Icons.cast),
          color: active ? Theme.of(context).colorScheme.primary : null,
          onPressed: () => showCastPicker(context, position: positionOf()),
        );
      },
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
    isScrollControlled: true,
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
  final _youtube = YouTubeCastController.instance;

  List<CastDevice>? _devices;
  List<YouTubeCastDevice>? _youtubeDevices;
  bool _sending = false;

  /// Her iki arama da bitti mi.
  bool get _searching => _devices == null || _youtubeDevices == null;

  @override
  void initState() {
    super.initState();
    _search();
  }

  /// İki keşif AYNI ANDA yürüyor.
  ///
  /// Sırayla çalıştırmak bekleme süresini ikiye katlıyordu ve ikisi de aynı
  /// ağ turunu bekliyor — biri diğerinin sonucuna ihtiyaç duymuyor. Sonuçlar
  /// geldikçe ayrı ayrı gösteriliyor, böylece hızlı biten liste yavaş olanı
  /// beklemiyor.
  Future<void> _search() async {
    setState(() {
      _devices = null;
      _youtubeDevices = null;
    });

    unawaited(
      _cast.search().then((found) {
        if (mounted) setState(() => _devices = found);
      }),
    );
    unawaited(
      _youtube.search().then((found) {
        if (mounted) setState(() => _youtubeDevices = found);
      }),
    );
  }

  Future<void> _send(CastDevice device) async {
    final details = PlaybackCoordinator.instance.details;
    if (details == null) return;

    setState(() => _sending = true);
    // Diğer yoldan yayın açıksa kapatılıyor: iki televizyonda birden çalan
    // ama tek kumandası olan bir durum kullanıcıya arıza gibi görünüyor.
    if (_youtube.isCasting) await _youtube.disconnect();

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
    // Hata mesajını oynatma ekranı gösteriyor (tek yerden), burada yalnızca
    // başarı bildiriliyor — yoksa aynı hata iki kez belirirdi.
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${device.name} cihazında açılıyor…')),
      );
    }
  }

  Future<void> _sendToYouTube(YouTubeCastDevice device) async {
    final details = PlaybackCoordinator.instance.details;
    if (details == null) return;

    setState(() => _sending = true);
    if (_cast.isCasting) await _cast.disconnect();

    final ok = await _youtube.castTo(
      device,
      videoId: details.videoId,
      title: details.title,
      thumbnailUrl: details.thumbnailUrl,
      position: widget.position,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    Navigator.of(context).pop();
    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text("${device.name} · YouTube'da açılıyor…")),
      );
    } else {
      // Bu yolun hatasını oynatma ekranı izlemiyor; burada gösterilmezse
      // kullanıcı hiçbir şey olmadığını sanır.
      final error = _youtube.lastError;
      _youtube.clearError();
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices ?? const <CastDevice>[];
    final youtubeDevices = _youtubeDevices ?? const <YouTubeCastDevice>[];
    final nothingFound =
        !_searching && devices.isEmpty && youtubeDevices.isEmpty;

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
                    onPressed: _searching ? null : _search,
                  ),
          ),
          if (_cast.isCasting)
            ListTile(
              leading: const Icon(Icons.cast_connected),
              title: Text(_cast.device!.name),
              subtitle: const Text('Şu an bu cihaza gönderiliyor'),
              trailing: TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  showCastDisconnectOptions(context);
                },
                child: const Text('Yayını bitir'),
              ),
            ),
          if (_youtube.isCasting)
            ListTile(
              leading: const Icon(Icons.smart_display),
              title: Text(_youtube.device!.name),
              subtitle: const Text("Şu an televizyonun YouTube'unda"),
              trailing: TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _youtube.disconnect();
                },
                child: const Text('Yayını bitir'),
              ),
            ),

          // Kendi uygulamamızın çalıştığı televizyonlar ÖNCE geliyor: tam
          // kumanda orada var, diğerinde yok.
          if (devices.isNotEmpty) ...[
            const _SectionHeader(
              title: 'oLusTifF kurulu televizyonlar',
              subtitle: 'Tam kumanda: sarma, kuyruk, ses',
            ),
            for (final device in devices)
              ListTile(
                leading: const Icon(Icons.tv),
                title: Text(device.name),
                subtitle: Text(device.host),
                enabled: !_sending,
                onTap: _sending ? null : () => _send(device),
              ),
          ],

          if (youtubeDevices.isNotEmpty) ...[
            const _SectionHeader(
              title: "Televizyonun kendi YouTube'u",
              subtitle: 'Oynat, duraklat ve ses; sarma televizyonun '
                  'kumandasından',
            ),
            for (final device in youtubeDevices)
              ListTile(
                leading: const Icon(Icons.smart_display_outlined),
                title: Text(device.name),
                subtitle: Text(device.host),
                enabled: !_sending,
                onTap: _sending ? null : () => _sendToYouTube(device),
              ),
          ],

          if (_searching)
            const ListTile(
              leading: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Televizyon aranıyor…'),
            ),
          if (nothingFound) const _NoDevicesFound(),
        ],
      ),
    );
  }
}

/// Listedeki iki grubu ayıran başlık.
///
/// Alt başlık şart: iki satır da "televizyon" diyor ama biri tam kumanda
/// veriyor, diğeri vermiyor. Farkı seçim ANINDA söylemek, kullanıcının
/// gönderdikten sonra eksikliği keşfetmesinden iyi.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          Text(subtitle, style: theme.textTheme.bodySmall),
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
            "• Televizyonun kendi YouTube'una gönderebilmek için televizyon "
            'açık olmalı (uyku modunda cevap vermez).\n'
            '• Bazı modemler 2.4 GHz ve 5 GHz ağlarındaki cihazların '
            'birbirini görmesini engeller; ikisini de aynı banda alıp '
            'tekrar deneyin.',
          ),
        ],
      ),
    );
  }
}

/// Sonucu beklenmeyen işler için; hata yutulmasın diye günlüğe yazılıyor.
void unawaited(Future<void> future) {
  future.catchError((Object e) {
    debugPrint('cast: arama başarısız: $e');
  });
}
