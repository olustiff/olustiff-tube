import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
        const SnackBar(content: Text('Açılamadı • github.com/olustiff/olustiff-tube')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.chat_outlined),
      title: const Text('Öneri ve görüş'),
      subtitle: const Text('GitHub üzerinden yaz'),
      onTap: () => _open(context),
    );
  }
}
