import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Ayarlardaki "öneri ve görüş" satırı: WhatsApp üzerinden geliştiriciye yazar.
class FeedbackTile extends StatelessWidget {
  const FeedbackTile({super.key});

  /// Uluslararası biçim (0 yerine ülke kodu) — wa.me bunu şart koşuyor.
  static const _phone = '[numara kaldırıldı]';

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse(
      'https://wa.me/$_phone?text=${Uri.encodeComponent('oLusTifF hakkında: ')}',
    );

    // WhatsApp kurulu değilse tarayıcıda açılır; o da olmazsa kullanıcıya
    // numarayı söyleyip elle yazabilmesini sağlıyoruz.
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('WhatsApp açılamadı •[numara kaldırıldı]')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.chat_outlined),
      title: const Text('Öneri ve görüş'),
      subtitle: const Text('WhatsApp ile yaz'),
      onTap: () => _open(context),
    );
  }
}
