import 'package:flutter/material.dart';

import '../../core/i18n/lang.dart';
import '../../core/update/update_service.dart';

/// Uygulama açılışında yeni sürümü haber veren pencere.
///
/// Denetim arka planda ve sessizce yapılır: ağ yoksa ya da sürüm kaynağına
/// ulaşılamıyorsa kullanıcı hiçbir şey görmez — açılışta hata penceresiyle
/// karşılaşmak can sıkıcı olurdu.
class UpdatePrompt {
  /// Uygulama bu açılışta zaten sordu mu. Ana ekran yeniden kurulduğunda
  /// (tema değişimi, geri dönüş) tekrar sormamak için.
  static bool _askedThisSession = false;

  /// Yeni sürüm varsa pencereyi gösterir. Çağıran beklemek zorunda değildir.
  static Future<void> maybeShow(BuildContext context) async {
    if (_askedThisSession) return;
    _askedThisSession = true;

    final service = UpdateService.instance;
    final release = await service.check();

    // Sürüm yok, hata var ya da kullanıcı bu sürümü zaten ertelemiş.
    if (release == null || service.error != null) return;
    if (service.isPostponed(release.version)) return;
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(release: release),
    );
  }
}

/// İndirme ilerlemesini de gösteren pencere: kullanıcı "güncelle" dedikten
/// sonra pencere kapanıp ortada kalmasın, işin bittiğini görsün.
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.release});

  final AppRelease release;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final _service = UpdateService.instance;

  Future<void> _update() async {
    await _service.downloadAndInstall(widget.release);
    if (!mounted) return;
    // Kurulum ekranını Android açar; pencerenin işi bitti.
    Navigator.of(context).pop();
    if (_service.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Kurulamadı: ${_service.error}',
              "Couldn't install: ${_service.error}")),
        ),
      );
    }
  }

  Future<void> _later() async {
    await _service.postpone(widget.release.version);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.release;

    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        final downloading = _service.isDownloading;

        return AlertDialog(
          icon: const Icon(Icons.system_update),
          title: Text(tr('Yeni sürüm hazır', 'New version available')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('Sürüm ${release.version} • ${release.sizeLabel}',
                    'Version ${release.version} • ${release.sizeLabel}'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (release.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: Text(
                      release.notes.trim(),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
              if (downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _service.progress),
                const SizedBox(height: 8),
                Text(tr('İndiriliyor… %${(_service.progress * 100).round()}',
                    'Downloading… ${(_service.progress * 100).round()}%')),
              ],
            ],
          ),
          actions: downloading
              ? const []
              : [
                  TextButton(
                    onPressed: _later,
                    child: Text(tr('Daha sonra', 'Later')),
                  ),
                  FilledButton.icon(
                    onPressed: _update,
                    icon: const Icon(Icons.download),
                    label: Text(tr('Güncelle', 'Update')),
                  ),
                ],
        );
      },
    );
  }
}
