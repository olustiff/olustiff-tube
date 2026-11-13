import 'package:flutter/material.dart';

import '../../core/i18n/lang.dart';

/// Ana sayfadaki liste türü.
enum HomeTab {
  /// En çok tekrar dinlenenler.
  forYou,

  /// Kullanıcının kalple işaretledikleri.
  favorites,
}

/// Ana sayfanın sekme çubuğu.
///
/// Material'ın `SegmentedButton`'ı yerine özel yazıldı: o bileşen dar
/// ekranlarda etiketleri kırpıyor ve seçili durumu yeterince belirgin
/// göstermiyordu. Buradaki kapsüller yumuşak geçişle doluyor.
class FeedTabs extends StatelessWidget {
  const FeedTabs({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final HomeTab selected;
  final ValueChanged<HomeTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: _TabChip(
              icon: Icons.auto_awesome,
              label: tr('Sana özel', 'For you'),
              isSelected: selected == HomeTab.forYou,
              onTap: () => onChanged(HomeTab.forYou),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _TabChip(
              icon: Icons.favorite,
              label: tr('Favoriler', 'Favorites'),
              isSelected: selected == HomeTab.favorites,
              onTap: () => onChanged(HomeTab.favorites),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground =
        isSelected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: isSelected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isSelected ? Colors.transparent : scheme.outlineVariant,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
