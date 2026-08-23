import 'package:flutter/material.dart';

import '../../core/update/update_service.dart';

/// Ayarlardaki güncelleme bölümü.
///
/// Sürümler GitHub Releases'ten okunur; yeni sürüm varsa APK indirilip
/// sistemin kurulum ekranı açılır. Mağazadan geçmediği için güncelleme
/// tamamen uygulama içinden yönetilir.
class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key});

  Future<void> _check(BuildContext context) async {
    final service = UpdateService.instance;
    final messenger = ScaffoldMessenger.of(context);

    final release = await service.check();
    if (service.error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Denetlenemedi: ${service.error}')),
      );
      return;
    }
    if (release == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('En güncel sürümü kullanıyorsun.')),
      );
    }
  }

  Future<void> _install(BuildContext context, AppRelease release) async {
    final service = UpdateService.instance;
    final messenger = ScaffoldMessenger.of(context);

    await service.downloadAndInstall(release);
    if (service.error != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Kurulamadı: ${service.error}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = UpdateService.instance;

    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final release = service.available;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.system_update),
              title: const Text('Güncellemeleri denetle'),
              subtitle: Text(
                release == null
                    ? 'Yüklü sürüm: ${service.currentVersion}'
                    : 'Yeni sürüm hazır: ${release.version}',
              ),
              trailing: service.isChecking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onTap: service.isChecking ? null : () => _check(context),
            ),
            if (release != null)
              Card(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sürüm ${release.version} • ${release.sizeLabel}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (release.notes.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          release.notes.trim(),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (service.isDownloading) ...[
                        LinearProgressIndicator(value: service.progress),
                        const SizedBox(height: 8),
                        Text('İndiriliyor… %${(service.progress * 100).round()}'),
                      ] else
                        FilledButton.icon(
                          onPressed: () => _install(context, release),
                          icon: const Icon(Icons.download),
                          label: const Text('İndir ve kur'),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'Kurulumu Android onaylatır. İlk seferde '
                        '"bilinmeyen kaynaklara izin ver" demen gerekebilir.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
