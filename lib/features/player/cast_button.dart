import 'package:flutter/material.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/cast/cast_targets.dart';
import '../../core/cast/cast_protocol.dart';
import '../../core/cast/youtube_cast_controller.dart';
import '../../core/cast/youtube_cast_protocol.dart';
import '../../core/playback/playback_coordinator.dart';
import 'cast_disconnect.dart';
import '../../core/i18n/lang.dart';

/// tr("TV'ye gönder", 'Cast to TV') düğmesi.
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
          tooltip: active ? tr('$name cihazına gönderiliyor', 'Casting to $name') : tr("TV'ye gönder", 'Cast to TV'),
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
        SnackBar(content: Text(tr('${device.name} cihazında açılıyor…', 'Opening on ${device.name}…'))),
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
        SnackBar(content: Text(tr("${device.name} · YouTube'da açılıyor…", '${device.name} · Opening in YouTube…'))),
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
    // İki keşif AYNI televizyonu bulabiliyor; listeye tek satır olarak
    // giriyor. Gerekçesi [mergeCastTargets] belgesinde.
    final targets = mergeCastTargets(youtubeDevices, devices);
    final nothingFound = !_searching && targets.isEmpty;

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(tr("TV'ye gönder", 'Cast to TV')),
            trailing: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: tr('Yeniden ara', 'Search again'),
                    icon: const Icon(Icons.refresh),
                    onPressed: _searching ? null : _search,
                  ),
          ),
          if (_cast.isCasting)
            ListTile(
              leading: const Icon(Icons.cast_connected),
              title: Text(_cast.device!.name),
              subtitle: Text(tr('Şu an bu cihaza gönderiliyor', 'Casting to this device now')),
              trailing: TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  showCastDisconnectOptions(context);
                },
                child: Text(tr('Yayını bitir', 'Stop casting')),
              ),
            ),
          if (_youtube.isCasting)
            ListTile(
              leading: const Icon(Icons.smart_display),
              title: Text(_youtube.device!.name),
              subtitle: Text(tr("Şu an televizyonun YouTube'unda", "Playing in the TV's YouTube app")),
              trailing: TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _youtube.disconnect();
                },
                child: Text(tr('Yayını bitir', 'Stop casting')),
              ),
            ),

          if (targets.isNotEmpty) ...[
            _SectionHeader(
              title: tr('Televizyonlar', 'TVs'),
              subtitle: tr('Sarma, oynat/duraklat ve ses telefondan', 'Seek, play/pause and volume from your phone'),
            ),
            for (final target in targets)
              _TargetTile(
                target: target,
                enabled: !_sending,
                onSendToYouTube: _sendToYouTube,
                onSendToApp: _send,
              ),
          ],

          if (_searching)
            ListTile(
              leading: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(tr('Televizyon aranıyor…', 'Searching for TVs…')),
            ),
          if (nothingFound) const _NoDevicesFound(),
        ],
      ),
    );
  }
}

/// Listedeki tek bir televizyon.
///
/// Televizyonun KENDİ YouTube'u varsa dokunma onu açıyor. Sebebi ölçüm: o
/// yolda videoyu televizyonun kendi oynatıcısı çözüyor ve pürüzsüz oynuyor;
/// bizim alıcımız aynı videoda birkaç saniyede bir duraklıyor. Eskiden bizim
/// yolumuz "tam kumanda" diye önce geliyordu — o gerekçe artık geçersiz,
/// çünkü sarma ve konum çubuğu bu yolda da var (yerel Cast kanalı).
///
/// İki yol da varsa diğeri gizlenmiyor, ikincil bir düğme olarak duruyor:
/// televizyondaki oLusTifF'in kendi kuyruğu ve arayüzü var, isteyen onu
/// seçebilmeli.
class _TargetTile extends StatelessWidget {
  const _TargetTile({
    required this.target,
    required this.enabled,
    required this.onSendToYouTube,
    required this.onSendToApp,
  });

  final CastTarget target;
  final bool enabled;
  final void Function(YouTubeCastDevice) onSendToYouTube;
  final void Function(CastDevice) onSendToApp;

  @override
  Widget build(BuildContext context) {
    final youtube = target.youtube;
    final ours = target.ours;

    final subtitle = youtube != null
        ? tr("${target.host} · Televizyonun kendi YouTube'u", "${target.host} · TV's own YouTube app")
        : tr('${target.host} · oLusTifF alıcısı', '${target.host} · oLusTifF receiver');

    return ListTile(
      leading: Icon(
        youtube != null ? Icons.smart_display_outlined : Icons.tv,
      ),
      title: Text(target.name),
      subtitle: Text(subtitle),
      enabled: enabled,
      trailing: target.hasBoth
          ? TextButton(
              onPressed: enabled ? () => onSendToApp(ours!) : null,
              child: Text(tr('oLusTifF ile', 'With oLusTifF')),
            )
          : null,
      onTap: !enabled
          ? null
          : () => youtube != null
              ? onSendToYouTube(youtube)
              : onSendToApp(ours!),
    );
  }
}

/// Listenin başlığı.
///
/// Alt başlık, kullanıcının seçmeden ÖNCE ne alacağını söylüyor: bir zamanlar
/// iki ayrı grup vardı ve hangisinin sarma verdiği ancak gönderdikten sonra
/// anlaşılıyordu.
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tv_off),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr('TV bulunamadı', 'No TV found'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              '• İki cihaz da AYNI Wi-Fi ağında olmalı.\n'
              "• Televizyonun kendi YouTube'una gönderebilmek için televizyon "
              'açık olmalı (uyku modunda cevap vermez).\n'
              '• Bazı modemler 2.4 GHz ve 5 GHz ağlarındaki cihazların '
              'birbirini görmesini engeller; ikisini de aynı banda alıp '
              'tekrar deneyin.',
              '• Both devices must be on the SAME Wi-Fi network.\n'
              "• To cast to the TV's own YouTube app, the TV must be on "
              "(it doesn't respond in sleep mode).\n"
              '• Some routers block devices on the 2.4 GHz and 5 GHz networks '
              'from seeing each other; put both on the same band and '
              'try again.',
            ),
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
