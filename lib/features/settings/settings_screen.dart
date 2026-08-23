import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/data/settings_store.dart';
import '../../core/playback/playback_client.dart';
import 'bluetooth_setting.dart';
import 'update_section.dart';

/// Oynatma tercihleri: kalite tavanı, hız ve otomatik oynatma.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          return ListView(
            children: [
              const _SectionHeader('Oynatma'),
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('Video kalitesi'),
                subtitle: Text(
                  settings.maxHeight == null
                      ? 'En yüksek (veri ve pil tüketimi yüksek)'
                      : 'En fazla ${settings.qualityLabel} — video daha düşük '
                          'çözünürlük sunuyorsa onunki geçerli olur',
                ),
                trailing: DropdownButton<int?>(
                  value: settings.maxHeight,
                  onChanged: settings.setMaxHeight,
                  items: [
                    for (final option in SettingsStore.qualityOptions)
                      DropdownMenuItem(
                        value: option,
                        child: Text(option == null ? 'En yüksek' : '${option}p'),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('Oynatma hızı'),
                subtitle: Text('${settings.speed}x'),
                trailing: DropdownButton<double>(
                  value: settings.speed,
                  onChanged: (value) async {
                    if (value == null) return;
                    await settings.setSpeed(value);
                    // Çalan medyaya hemen uygulansın.
                    await PlaybackClient.shared.setSpeed(value);
                  },
                  items: [
                    for (final option in SettingsStore.speedOptions)
                      DropdownMenuItem(value: option, child: Text('${option}x')),
                  ],
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.headphones),
                title: const Text('Müzikleri sesli modda başlat'),
                subtitle: const Text(
                  'Şarkı ve müzik videoları görüntü indirilmeden açılır. '
                  'Kapatırsan her şey video olarak başlar.',
                ),
                value: settings.musicAsAudio,
                onChanged: settings.setMusicAsAudio,
              ),
              const BluetoothSetting(),
              SwitchListTile(
                secondary: const Icon(Icons.playlist_play),
                title: const Text('Otomatik oynatma'),
                subtitle: const Text(
                  'Parça bitince sıradakine geçer (ekran kapalıyken de).',
                ),
                value: settings.autoplay,
                onChanged: (value) async {
                  await settings.setAutoplay(value);
                  await PlaybackClient.shared.setAutoplay(value);
                },
              ),
              const Divider(),
              const _SectionHeader('Uygulama'),
              const UpdateSection(),
              const Divider(),
              const _SectionHeader('Veriler'),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('İzleme geçmişini temizle'),
                onTap: () => LibraryStore.instance.clearWatched(),
              ),
              ListTile(
                leading: const Icon(Icons.search_off),
                title: const Text('Arama geçmişini temizle'),
                subtitle: const Text('Ana sayfa önerileri de sıfırlanır.'),
                onTap: () => LibraryStore.instance.clearSearches(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
