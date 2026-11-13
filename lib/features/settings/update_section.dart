import 'package:flutter/material.dart';

import '../../core/i18n/lang.dart';
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
        SnackBar(
          content: Text(tr('Denetlenemedi: ${service.error}',
              "Couldn't check: ${service.error}")),
        ),
      );
      return;
    }
    if (release == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('En güncel sürümü kullanıyorsun.',
              "You're on the latest version.")),
        ),
      );
    }
  }

  Future<void> _install(BuildContext context, AppRelease release) async {
    final service = UpdateService.instance;
    final messenger = ScaffoldMessenger.of(context);

    await service.downloadAndInstall(release);
    if (service.error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('Kurulamadı: ${service.error}',
              "Couldn't install: ${service.error}")),
        ),
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
              title: Text(tr('Güncellemeleri denetle', 'Check for updates')),
              subtitle: Text(
                release == null
                    ? tr('Yüklü sürüm: ${service.currentVersion}',
                        'Installed version: ${service.currentVersion}')
                    : tr('Yeni sürüm hazır: ${release.version}',
                        'New version available: ${release.version}'),
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
                        tr('Sürüm ${release.version} • ${release.sizeLabel}',
                            'Version ${release.version} • ${release.sizeLabel}'),
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
                        Text(tr(
                          'İndiriliyor… %${(service.progress * 100).round()}',
                          'Downloading… ${(service.progress * 100).round()}%',
                        )),
                      ] else
                        FilledButton.icon(
                          onPressed: () => _install(context, release),
                          icon: const Icon(Icons.download),
                          label: Text(tr('İndir ve kur', 'Download and install')),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          'Kurulumu Android onaylatır. İlk seferde '
                              '"bilinmeyen kaynaklara izin ver" demen gerekebilir.',
                          'Android will ask you to confirm the install. The first '
                              'time, you may need to allow installs from unknown '
                              'sources.',
                        ),
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
