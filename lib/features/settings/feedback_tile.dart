import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/lang.dart';

/// Ayarlardaki "öneri ve görüş" satırı: projenin GitHub'daki öneri/hata
/// sayfasını açar.
///
/// Önceden geliştiricinin WhatsApp numarasına yazıyordu; proje herkese
/// açılınca kişisel numara kodda durmasın diye GitHub'a taşındı.
class FeedbackTile extends StatelessWidget {
  const FeedbackTile({super.key});

  static final _issues = Uri.parse('https://github.com/olustiff/olustiff-tube/issues');

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await launchUrl(_issues, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tr('Açılamadı • github.com/olustiff/olustiff-tube',
                "Couldn't open • github.com/olustiff/olustiff-tube"),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.chat_outlined),
      title: Text(tr('Öneri ve görüş', 'Feedback')),
      subtitle: Text(tr('GitHub üzerinden yaz', 'Write to us on GitHub')),
      onTap: () => _open(context),
    );
  }
}
