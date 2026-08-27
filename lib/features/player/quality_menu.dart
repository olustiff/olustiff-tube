import 'package:flutter/material.dart';

import '../../core/data/settings_store.dart';
import '../../core/playback/playback_client.dart';
import '../../core/playback/playback_coordinator.dart';

/// Kalite seçimi.
///
/// Seçenekler videonun GERÇEKTEN sunduğu çözünürlüklerden üretilir; sabit bir
/// liste, 4K sunmayan bir videoda "2160p" göstermeye yol açardı. Seçim çalan
/// videoya hemen uygulanır ve oynatma konumu korunur.
///
/// Listenin başındaki "Otomatik" bir çözünürlük SABİTLEMEZ: oynatıcıya tüm
/// çözünürlükleri içeren bir manifest verilir ve o, indirme hızına göre
/// aralarında geçiş yapar.
Future<void> showQualityMenu(BuildContext context) async {
  final coordinator = PlaybackCoordinator.instance;
  final settings = SettingsStore.instance;
  final available = coordinator.availableQualities;

  if (available.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bu video için kalite seçeneği yok.')),
    );
    return;
  }

  final current = settings.maxHeight;

  final selected = await showModalBottomSheet<_QualityChoice>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Video kalitesi')),
          const _AutoQualityTile(),
          for (final height in available)
            _QualityTile(
              label: '${height}p',
              selected: current == height,
              height: height,
            ),
        ],
      ),
    ),
  );

  if (selected == null) return;
  await coordinator.setQuality(selected.height);
}

/// Dropdown yerine radyo listesi kullanıldığı için seçim değerini sarmalıyoruz;
/// `null` ("Otomatik") ile bir yüksekliği aynı tipte taşıyabilmek gerekiyor.
class _QualityChoice {
  const _QualityChoice(this.height);

  final int? height;

  @override
  bool operator ==(Object other) =>
      other is _QualityChoice && other.height == height;

  @override
  int get hashCode => height.hashCode;
}

/// "Otomatik" satırı, o an gerçekten oynatılan çözünürlüğü de gösterir.
///
/// Çözünürlük ağ hızıyla birlikte değiştiği için sabit bir metin yanıltıcı
/// olurdu; değer oynatıcının anlık durumundan okunuyor.
class _AutoQualityTile extends StatelessWidget {
  const _AutoQualityTile();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: PlaybackClient.shared.stateStream,
      builder: (context, snapshot) {
        final height = snapshot.data?.videoHeight ?? 0;
        return _QualityTile(
          label: 'Otomatik',
          subtitle: height > 0
              ? 'Ağ hızına göre — şu an ${height}p'
              : 'Ağ hızına göre ayarlanır',
          selected: SettingsStore.instance.maxHeight == null,
          height: null,
        );
      },
    );
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({
    required this.label,
    required this.selected,
    required this.height,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final int? height;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => Navigator.of(context).pop(_QualityChoice(height)),
    );
  }
}
