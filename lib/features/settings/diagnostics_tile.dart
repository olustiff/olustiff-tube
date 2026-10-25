import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/playback/ui_channel.dart';

/// Ayarlardaki "Tanılama kaydını paylaş" satırı.
///
/// Takılma ya da kopma yaşandığında oynatıcı bunu telefondaki bir dosyaya
/// yazıyor. Bu satır o dosyayı WhatsApp/e-posta ile gönderilebilir kılıyor;
/// önceden okumak için telefonun bilgisayara takılması gerekiyordu.
/// Dosyada şarkı adı ya da akış adresi yok: yalnızca olay türü, video
/// kimliği, süreler ve ağ türü.
class DiagnosticsTile extends StatelessWidget {
  const DiagnosticsTile({super.key});

  Future<void> _share(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await UiChannel.instance.diagnosticsFile();
    if (path == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Henüz kaydedilmiş bir sorun yok')),
      );
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'text/plain')],
        subject: 'oLusTifF tanılama kaydı',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bug_report_outlined),
      title: const Text('Tanılama kaydını paylaş'),
      subtitle: const Text('Takılma veya kopma olduysa geliştiriciye gönder'),
      onTap: () => _share(context),
    );
  }
}
