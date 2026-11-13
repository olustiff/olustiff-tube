import 'package:flutter/material.dart';

import '../../core/i18n/lang.dart';

/// Arayüz dili: sistem / Türkçe / English.
class LanguageTile extends StatelessWidget {
  const LanguageTile({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = Lang.instance;
    return ListTile(
      leading: const Icon(Icons.language),
      title: Text(tr('Dil', 'Language')),
      trailing: DropdownButton<AppLanguage>(
        value: lang.choice,
        onChanged: (value) {
          if (value != null) lang.setChoice(value);
        },
        items: [
          DropdownMenuItem(
            value: AppLanguage.system,
            child: Text(tr('Telefonun dili', 'System')),
          ),
          // Dil adları kendi dillerinde yazılıyor: yanlış dili seçen kullanıcı
          // da kendi dilini tanıyabilsin.
          const DropdownMenuItem(
            value: AppLanguage.turkish,
            child: Text('Türkçe'),
          ),
          const DropdownMenuItem(
            value: AppLanguage.english,
            child: Text('English'),
          ),
        ],
      ),
    );
  }
}
