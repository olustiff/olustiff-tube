import 'package:flutter/material.dart';

/// Bir tuşun ne iş yaptığı.
enum TvKeyKind { character, space, backspace, clear, search, voice, toggleMode }

/// Ekran klavyesindeki tek bir tuş.
class TvKey {
  const TvKey.character(String character)
      : kind = TvKeyKind.character,
        label = character,
        value = character,
        span = 1;

  const TvKey.action(this.kind, this.label, {this.span = 1}) : value = null;

  final TvKeyKind kind;

  /// Tuşun üzerinde yazan. Eylem tuşlarında simge de kullanılıyor
  /// (bkz. [TvKeyboard]); bu metin erişilebilirlik etiketi olarak kalıyor.
  final String label;

  /// Yalnızca harf/rakam tuşlarında dolu.
  final String? value;

  /// Tuşun kaç sütun genişliğinde olduğu. "Boşluk" tuşu geniş olsun diye var.
  final int span;
}

/// Klavyedeki seçim: hangi satırın kaçıncı tuşu.
@immutable
class TvKeyPosition {
  const TvKeyPosition(this.row, this.column);

  final int row;
  final int column;

  @override
  bool operator ==(Object other) =>
      other is TvKeyPosition && other.row == row && other.column == column;

  @override
  int get hashCode => Object.hash(row, column);

  @override
  String toString() => 'TvKeyPosition($row, $column)';
}

/// Kumandayla gezilen harf ızgarasının düzeni ve gezinme kuralları.
///
/// Arayüzden ayrı bir sınıf: hangi tuşun nerede olduğu ve ok tuşunun nereye
/// götürdüğü, widget kurmadan test edilebilmeli.
class TvKeyboardLayout {
  const TvKeyboardLayout(this.rows);

  final List<List<TvKey>> rows;

  /// Izgara kaç sütun.
  ///
  /// 8 sütun: 32 harf tam 4 satıra oturuyor, artan tuş kalmıyor. 6 sütunda
  /// son satırda iki harf kalıyor ve satırı doldurmak için kocaman
  /// görünüyorlardı.
  static const columns = 8;

  /// Türkçe alfabe + yabancı adlar için q/w/x.
  ///
  /// Alfabe sırası korunuyor: kullanıcı harfi nerede arayacağını biliyor.
  /// q, w, x Türkçe alfabede yok ama aranan şarkıların çoğu yabancı —
  /// olmadıklarında "wonderwall" yazmak imkânsız oluyordu.
  static const alphabet = 'abcçdefgğhıijklmnoöpqrsştuüvwxyz';

  /// Rakamlar ve sık kullanılan işaretler.
  ///
  /// Ayrı sayfada: hepsi harflerle aynı ızgaraya konunca 7 satır oluyor,
  /// alt sıradaki eylem tuşları ekranın dışında kalıyordu.
  static const symbolChars = "0123456789.,'&-_!?+@#/:*";

  /// Yabancı dillerin aksanlı harfleri.
  ///
  /// Türkçe klavyede olmayan bu harfler olmadan "Beyoncé", "Björk", "Señor"
  /// gibi adlar yazılamıyordu. 24 karakter: 8 sütuna tam 3 satır.
  static const accentChars = 'àáâäãåæèéêëìíîïñòóôõùúûß';

  /// Harf sayfası.
  factory TvKeyboardLayout.turkish({bool withVoice = true}) =>
      TvKeyboardLayout._page(alphabet, TvKeyKind.toggleMode, '123',
          withVoice: withVoice);

  /// Rakam ve işaret sayfası.
  factory TvKeyboardLayout.symbols({bool withVoice = true}) =>
      TvKeyboardLayout._page(symbolChars, TvKeyKind.toggleMode, 'àé',
          withVoice: withVoice);

  /// Yabancı dillerin aksanlı harf sayfası.
  factory TvKeyboardLayout.accents({bool withVoice = true}) =>
      TvKeyboardLayout._page(accentChars, TvKeyKind.toggleMode, 'ABC',
          withVoice: withVoice);

  /// İki sayfa da aynı iskeleti kullanıyor: karakter ızgarası + eylem satırı.
  ///
  /// [withVoice] false ise mikrofon tuşu HİÇ çizilmez: cihazda ses tanıma
  /// yoksa basınca bir şey olmayan tuş kullanıcıyı yanıltır. Tuş
  /// kaybolunca "Ara" genişleyerek boşluğu kapatır.
  factory TvKeyboardLayout._page(
    String characters,
    TvKeyKind toggleKind,
    String toggleLabel, {
    required bool withVoice,
  }) {
    final keys = characters.runes.map(String.fromCharCode).toList();
    final rows = <List<TvKey>>[
      for (var start = 0; start < keys.length; start += columns)
        [
          for (final key in keys.skip(start).take(columns))
            TvKey.character(key),
        ],
      // Eylem satırı da tam 6 sütun.
      [
        TvKey.action(toggleKind, toggleLabel),
        // "Temizle" kaldırıldı: simgesi ne işe yaradığını anlatmıyordu ve
        // "Sil" zaten var. Boşluk genişleyip yerini kapatıyor.
        const TvKey.action(TvKeyKind.space, 'Boşluk', span: 4),
        const TvKey.action(TvKeyKind.backspace, 'Sil'),
        if (withVoice) ...[
          const TvKey.action(TvKeyKind.search, 'Ara'),
          const TvKey.action(TvKeyKind.voice, 'Mikrofon'),
        ] else
          const TvKey.action(TvKeyKind.search, 'Ara', span: 2),
      ],
    ];
    return TvKeyboardLayout(rows);
  }

  TvKey keyAt(TvKeyPosition position) => rows[position.row][position.column];

  /// Seçimin ızgarada geçerli olduğundan emin olur.
  ///
  /// Mikrofon tuşu, cihaz yanıtı geldikten sonra kaybolabiliyor; o anda
  /// seçim satır dışında kalırsa çizim çökerdi.
  TvKeyPosition clamp(TvKeyPosition position) {
    final row = position.row.clamp(0, rows.length - 1);
    final column = position.column.clamp(0, rows[row].length - 1);
    return TvKeyPosition(row, column);
  }

  /// Tuşun satır içindeki yatay ORTASI (sütun cinsinden).
  ///
  /// Yukarı/aşağı geçişte kullanılıyor: satırlar farklı sayıda tuş
  /// içerebildiği için "aynı sütun" diye bir şey yok; parmağın ekranda
  /// kaldığı yere en yakın tuşa gitmek doğru his veriyor.
  double centerOf(TvKeyPosition position) {
    var left = 0.0;
    final row = rows[position.row];
    for (var i = 0; i < position.column; i++) {
      left += row[i].span;
    }
    return left + row[position.column].span / 2;
  }

  int _nearestColumn(int row, double center) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var column = 0; column < rows[row].length; column++) {
      final distance = (centerOf(TvKeyPosition(row, column)) - center).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = column;
      }
    }
    return best;
  }

  /// Ok tuşunun götürdüğü yer. Izgaranın dışına çıkılıyorsa null döner —
  /// çağıran ekran o zaman odağı sağdaki listeye taşıyabilir.
  TvKeyPosition? move(TvKeyPosition from, TraversalDirection direction) {
    final current = clamp(from);
    switch (direction) {
      case TraversalDirection.left:
        if (current.column == 0) return null;
        return TvKeyPosition(current.row, current.column - 1);
      case TraversalDirection.right:
        if (current.column >= rows[current.row].length - 1) return null;
        return TvKeyPosition(current.row, current.column + 1);
      case TraversalDirection.up:
        if (current.row == 0) return null;
        final row = current.row - 1;
        return TvKeyPosition(row, _nearestColumn(row, centerOf(current)));
      case TraversalDirection.down:
        if (current.row >= rows.length - 1) return null;
        final row = current.row + 1;
        return TvKeyPosition(row, _nearestColumn(row, centerOf(current)));
    }
  }

  /// Tuşa basıldığında arama metninin ne olacağı.
  ///
  /// Metni ekranın kendisi değil bu fonksiyon kuruyor ki "sil" ve "boşluk"
  /// kuralları tek yerde ve test edilebilir olsun.
  static String apply(String query, TvKey key) {
    switch (key.kind) {
      // Sayfa değiştirme yalnızca ızgarayı değiştirir, metne dokunmaz.
      case TvKeyKind.toggleMode:
        return query;
      case TvKeyKind.character:
        return query + key.value!;
      case TvKeyKind.space:
        // Baştaki ve üst üste boşluklar aramayı bozuyor, sadece görüntüyü
        // kirletiyor.
        if (query.isEmpty || query.endsWith(' ')) return query;
        return '$query ';
      case TvKeyKind.backspace:
        if (query.isEmpty) return query;
        // Kod noktası olarak siliniyor: sesli aramadan gelen metinde tek
        // UTF-16 birimine sığmayan karakterler olabilir ve yarısını silmek
        // metni bozardı.
        final runes = query.runes.toList()..removeLast();
        return String.fromCharCodes(runes);
      case TvKeyKind.clear:
        return '';
      case TvKeyKind.search:
      case TvKeyKind.voice:
        // Bu tuşlar metni değiştirmez; ekran ayrı bir iş yapar.
        return query;
    }
  }
}

/// Harf ızgarasının çizimi.
///
/// Odak Flutter'ın gezinme mekanizmasına BIRAKILMIYOR: hangi tuşun seçili
/// olduğunu ekran ([TvSearchScreen]) tutuyor ve buraya [selection] olarak
/// veriyor. Televizyonda odak dolaşımı beklenmedik yerlere atlıyordu; her
/// tuşun nereye gideceği kesin olmalı.
class TvKeyboard extends StatelessWidget {
  const TvKeyboard({
    super.key,
    required this.layout,
    required this.selection,
    required this.active,
    this.onTap,
  });

  final TvKeyboardLayout layout;
  final TvKeyPosition selection;

  /// Seçim çerçevesi ızgarada mı, yoksa sağdaki listede mi.
  final bool active;

  /// Dokunmatik ekranlı TV kutuları/emülatör için; kumandada kullanılmıyor.
  final void Function(TvKeyPosition position)? onTap;

  static IconData? iconOf(TvKeyKind kind) {
    switch (kind) {
      // Sayfa tuşunda simge değil "123" / "ABC" yazısı gösteriliyor.
      case TvKeyKind.toggleMode:
        return null;
      case TvKeyKind.space:
        return Icons.space_bar;
      case TvKeyKind.backspace:
        return Icons.backspace_outlined;
      case TvKeyKind.clear:
        return Icons.clear_all;
      case TvKeyKind.search:
        return Icons.search;
      case TvKeyKind.voice:
        return Icons.mic;
      case TvKeyKind.character:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < layout.rows.length; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (var column = 0; column < layout.rows[row].length; column++)
                  Expanded(
                    flex: layout.rows[row][column].span,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _KeyCap(
                        item: layout.rows[row][column],
                        selected: active &&
                            selection.row == row &&
                            selection.column == column,
                        onTap: onTap == null
                            ? null
                            : () => onTap!(TvKeyPosition(row, column)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.item, required this.selected, this.onTap});

  final TvKey item;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = TvKeyboard.iconOf(item.kind);

    return Semantics(
      label: item.label,
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary
                : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            // Televizyon mesafesinden ince bir çerçeve seçilmiyor; kalın
            // çerçeve + dolgu birlikte kullanılıyor.
            border: Border.all(
              color: selected ? scheme.onPrimary : Colors.transparent,
              width: 3,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: icon != null
              ? Icon(
                  icon,
                  size: 24,
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                )
              // Harfler BÜYÜTÜLMÜYOR: Dart'ın toUpperCase'i Türkçe bilmiyor
              // ve "i" → "I" veriyor. Kullanıcı "İ" bekleyip "ı" yazdığını
              // sanırdı. Tuşun üstünde yazan, yazılacak harfin ta kendisi.
              : Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
        ),
      ),
    );
  }
}
