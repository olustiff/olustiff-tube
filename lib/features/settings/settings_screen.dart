import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/data/settings_store.dart';
import '../../core/i18n/lang.dart';
import '../../core/playback/playback_client.dart';
import '../../core/ui/tv_mode.dart';
import 'bluetooth_setting.dart';
import 'cast_receiver_setting.dart';
import 'diagnostics_tile.dart';
import 'feedback_tile.dart';
import 'language_tile.dart';
import 'update_section.dart';

/// Oynatma tercihleri: kalite tavanı, hız ve otomatik oynatma.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsStore.instance;

    return Scaffold(
      appBar: AppBar(title: Text(tr('Ayarlar', 'Settings'))),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          return ListView(
            children: [
              _SectionHeader(tr('Oynatma', 'Playback')),
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: Text(tr('Video kalitesi', 'Video quality')),
                subtitle: Text(
                  settings.maxHeight == null
                      ? tr(
                          'Otomatik — çözünürlük ağ hızına göre kendiliğinden '
                              'ayarlanır',
                          'Auto — resolution adjusts to your network speed',
                        )
                      : tr(
                          'En fazla ${settings.qualityLabel} — video daha düşük '
                              'çözünürlük sunuyorsa onunki geçerli olur',
                          'Up to ${settings.qualityLabel} — if the video offers '
                              'less, that is used',
                        ),
                ),
                trailing: DropdownButton<int?>(
                  value: settings.maxHeight,
                  onChanged: settings.setMaxHeight,
                  items: [
                    for (final option in SettingsStore.qualityOptions)
                      DropdownMenuItem(
                        value: option,
                        child: Text(
                          option == null ? tr('Otomatik', 'Auto') : '${option}p',
                        ),
                      ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(tr('Oynatma hızı', 'Playback speed')),
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
              ListTile(
                leading: const Icon(Icons.volume_up_outlined),
                title: Text(tr('Ses yükseltme', 'Volume boost')),
                subtitle: Text(
                  settings.loudnessBoost == 0
                      ? tr('Kapalı — ses ham hâliyle, en temiz sonuç',
                          'Off — original audio, cleanest sound')
                      : tr(
                          '${settings.loudnessLabel} — yüksek kademelerde ses '
                              'bir sıkılıp bir açılabilir',
                          '${settings.loudnessLabel} — at higher levels the '
                              'volume may pump up and down',
                        ),
                ),
                trailing: DropdownButton<int>(
                  value: settings.loudnessBoost,
                  onChanged: (value) async {
                    if (value == null) return;
                    await settings.setLoudnessBoost(value);
                  },
                  items: [
                    for (final option in SettingsStore.loudnessOptions)
                      DropdownMenuItem(
                        value: option,
                        child: Text(
                          option == 0 ? tr('Kapalı', 'Off') : '+${option ~/ 100} dB',
                        ),
                      ),
                  ],
                ),
              ),
              // Televizyonda sesli mod hiç kullanılmıyor (ekran zaten
              // karşıda); orada bu ayarı göstermek kafa karıştırıyor.
              if (!TvMode.isTv.value)
                SwitchListTile(
                  secondary: const Icon(Icons.headphones),
                  title: Text(
                    tr('Müzikleri sesli modda başlat', 'Play music as audio'),
                  ),
                  subtitle: Text(
                    tr(
                      'Şarkı ve müzik videoları görüntü indirilmeden açılır. '
                          'Kapatırsan her şey video olarak başlar. Oynatıcıda modu '
                          'elle değiştirirsen sonrakiler de o modda açılır.',
                      'Songs and music videos open without downloading the '
                          'video. Turn off to start everything as video. If you '
                          'switch modes in the player, the next ones follow it.',
                    ),
                  ),
                  value: settings.musicAsAudio,
                  onChanged: settings.setMusicAsAudio,
                ),
              const BluetoothSetting(),
              // Yalnızca televizyonda: telefondan gelen yayını karşılayan
              // taraf orası. Telefonda gösterilecek bir karşılığı yok.
              if (TvMode.isTv.value) const CastReceiverSetting(),
              SwitchListTile(
                secondary: const Icon(Icons.fast_forward_outlined),
                title: Text(tr('Sponsor bölümlerini atla', 'Skip sponsor segments')),
                subtitle: Text(tr(
                  'SponsorBlock: videoya gömülü sponsor, tanıtım ve "abone '
                      'ol" kısımlarını, müzik videolarındaki müzik dışı '
                      'bölümleri atlar.',
                  'SponsorBlock: skips sponsor segments, self-promotion, '
                      'subscribe reminders and non-music parts of music videos.',
                )),
                value: settings.sponsorBlock,
                onChanged: settings.setSponsorBlock,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.playlist_play),
                title: Text(tr('Otomatik oynatma', 'Autoplay')),
                subtitle: Text(
                  tr(
                    'Parça bitince sıradakine geçer (ekran kapalıyken de).',
                    'Plays the next track when one ends (even with the '
                        'screen off).',
                  ),
                ),
                value: settings.autoplay,
                onChanged: (value) async {
                  await settings.setAutoplay(value);
                  await PlaybackClient.shared.setAutoplay(value);
                },
              ),
              const Divider(),
              _SectionHeader(tr('Uygulama', 'App')),
              const LanguageTile(),
              const UpdateSection(),
              const FeedbackTile(),
              const DiagnosticsTile(),
              const Divider(),
              _SectionHeader(tr('Veriler', 'Data')),
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(
                  tr('İzleme geçmişini temizle', 'Clear watch history'),
                ),
                subtitle: Text(
                  tr('"Sana özel" listesi de sıfırlanır.',
                      'This also resets "For you".'),
                ),
                onTap: () => LibraryStore.instance.clearWatched(),
              ),
              ListTile(
                leading: const Icon(Icons.search_off),
                title: Text(
                  tr('Arama geçmişini temizle', 'Clear search history'),
                ),
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
