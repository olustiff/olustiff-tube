import 'dart:async';

/// Arama önerilerinin iki kaynağını tek listede birleştirir: kullanıcının
/// kendi arama geçmişi ve YouTube'un otomatik tamamlamaları.
///
/// Arayüzden ayrı tutuluyor çünkü aynı mantık hem televizyon hem telefon
/// arama ekranında kullanılıyor.
class SearchSuggestions {
  const SearchSuggestions._();

  /// Karşılaştırma için metni küçültür.
  ///
  /// Dart'ın [String.toLowerCase] metodu Türkçe'yi bilmiyor: "İ" → "i̇"
  /// (birleşik nokta) ve "I" → "i" veriyor. Bu yüzden "IŞIK" ile "ışık"
  /// aynı sayılmıyor ve kullanıcı kendi geçmişini bulamıyordu.
  static String fold(String value) => value
      .replaceAll('İ', 'i')
      .replaceAll('I', 'ı')
      .toLowerCase();

  /// Gösterilecek öneri listesi.
  ///
  /// Geçmiş HER ZAMAN önce gelir: kullanıcının daha önce aradığı şeyi tekrar
  /// araması, genel bir tamamlamaya tıklamasından daha olası.
  ///
  /// Sorgu boşken uzak öneri zaten olmaz; liste kullanıcının son aramaları
  /// olur.
  static List<String> merge({
    required String query,
    required List<String> history,
    required List<String> remote,
    int limit = 12,
  }) {
    final needle = fold(query.trim());
    final seen = <String>{};
    final merged = <String>[];

    void add(String candidate) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty) return;
      // Aynı arama hem geçmişte hem YouTube önerisinde çıkabiliyor; iki kez
      // görünmesi listeyi kısaltıyor ve kafa karıştırıyor.
      if (!seen.add(fold(trimmed))) return;
      merged.add(trimmed);
    }

    for (final past in history) {
      if (merged.length >= limit) break;
      if (needle.isEmpty || fold(past).contains(needle)) add(past);
    }
    for (final suggestion in remote) {
      if (merged.length >= limit) break;
      add(suggestion);
    }
    return merged;
  }

  /// [merge] sonucundaki bir önerinin geçmişten mi geldiği.
  ///
  /// Arayüz simgeyi (saat / büyüteç) ve "geçmişten sil" düğmesini buna göre
  /// veriyor.
  static bool isFromHistory(String suggestion, List<String> history) {
    final folded = fold(suggestion);
    return history.any((past) => fold(past) == folded);
  }
}

/// Yazdıkça öneri isteyen, ama her tuşta ağa gitmeyen yükleyici.
///
/// İki sorunu birden çözüyor:
/// - Her harfte istek atmak: kumandayla "sezen aksu" yazmak 10 istek demek.
///   Bu yüzden son tuştan [debounce] kadar sonra tek istek atılıyor.
/// - Yanıtların sırasız dönmesi: "sez" isteği "sezen"den sonra gelirse
///   kullanıcı yazdığıyla alakasız öneriler görüyordu. Her isteğin bir
///   numarası var; eskimiş yanıt atılıyor.
class SuggestionLoader {
  SuggestionLoader({
    required this.fetch,
    this.debounce = const Duration(milliseconds: 300),
  });

  final Future<List<String>> Function(String query) fetch;
  final Duration debounce;

  Timer? _timer;
  int _requestId = 0;
  bool _disposed = false;

  /// Sorgu için öneri ister. Sonuç geldiğinde [onResult] çağrılır.
  ///
  /// Ağ hatasında [onResult] HİÇ çağrılmaz: kullanıcı yazmaya çalışırken
  /// hata mesajı görmemeli, eldeki geçmiş önerileriyle devam etmeli.
  void request(String query, void Function(List<String> remote) onResult) {
    _timer?.cancel();
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      // Boş sorguda uzak öneri yok; bekleyen yanıtlar da geçersiz kılınır ki
      // kullanıcı yazdığını silince eski öneriler geri gelmesin.
      _requestId++;
      onResult(const []);
      return;
    }
    _timer = Timer(debounce, () {
      final id = ++_requestId;
      fetch(trimmed).then(
        (remote) {
          if (_disposed || id != _requestId) return;
          onResult(remote);
        },
        onError: (Object _) {
          // Sessizce geç: öneri, aramanın kendisi değil, kolaylığı.
        },
      );
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
