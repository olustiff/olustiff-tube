import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:olustiff/features/search/search_suggestions.dart';

void main() {
  group('SearchSuggestions.merge', () {
    test('sorgu boşken kullanıcının son aramaları listelenir', () {
      final merged = SearchSuggestions.merge(
        query: '',
        history: ['sezen aksu', 'lofi'],
        remote: const [],
      );

      expect(merged, ['sezen aksu', 'lofi']);
    });

    test('geçmiş ve uzak öneriler birleşir, geçmiş önce gelir', () {
      final merged = SearchSuggestions.merge(
        query: 'se',
        history: ['sezen aksu'],
        remote: ['selena gomez', 'serdar ortaç'],
      );

      expect(merged, ['sezen aksu', 'selena gomez', 'serdar ortaç'],
          reason: 'kullanıcının kendi aramasını tekrar araması daha olası');
    });

    test('sorguya uymayan geçmiş kaydı listede yer almaz', () {
      final merged = SearchSuggestions.merge(
        query: 'se',
        history: ['lofi', 'sezen aksu'],
        remote: const [],
      );

      expect(merged, ['sezen aksu']);
    });

    test('aynı arama iki kaynaktan gelse de bir kez gösterilir', () {
      final merged = SearchSuggestions.merge(
        query: 'sez',
        history: ['Sezen Aksu'],
        remote: ['sezen aksu', 'sezen aksu şarkıları'],
      );

      expect(merged, ['Sezen Aksu', 'sezen aksu şarkıları'],
          reason: 'tekrar eden öneri listeyi kısaltıyor ve kafa karıştırıyor');
    });

    test('Türkçe büyük/küçük harf eşleşmesi doğru yapılır', () {
      // Dart'ın toLowerCase'i "IŞIK" → "ışık" vermiyor; kullanıcı kendi
      // geçmişini bulamıyordu.
      final merged = SearchSuggestions.merge(
        query: 'ışık',
        history: ['IŞIK'],
        remote: const [],
      );

      expect(merged, ['IŞIK']);
      expect(SearchSuggestions.fold('İSTANBUL'), 'istanbul');
    });

    test('liste sınırı aşılmaz', () {
      final merged = SearchSuggestions.merge(
        query: '',
        history: [for (var i = 0; i < 30; i++) 'arama $i'],
        remote: const [],
        limit: 5,
      );

      expect(merged, hasLength(5));
    });

    test('geçmişten gelen öneri işaretlenir', () {
      expect(SearchSuggestions.isFromHistory('Lofi', ['lofi']), isTrue,
          reason: 'arayüz saat simgesini ve "geçmişten sil" düğmesini buna göre veriyor');
      expect(SearchSuggestions.isFromHistory('jazz', ['lofi']), isFalse);
    });
  });

  group('SuggestionLoader', () {
    test('peş peşe yazılan harfler için tek istek atılır', () async {
      final istenenler = <String>[];
      final loader = SuggestionLoader(
        debounce: const Duration(milliseconds: 20),
        fetch: (query) async {
          istenenler.add(query);
          return ['$query önerisi'];
        },
      );
      addTearDown(loader.dispose);

      var sonuc = <String>[];
      loader.request('s', (r) => sonuc = r);
      loader.request('se', (r) => sonuc = r);
      loader.request('sez', (r) => sonuc = r);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(istenenler, ['sez'],
          reason: 'kumandayla yazarken her tuşta ağa gitmek gereksiz');
      expect(sonuc, ['sez önerisi']);
    });

    test('geciken eski yanıt yeni sorgunun önerilerini ezmez', () async {
      final bekleyenler = <String, Completer<List<String>>>{};
      final loader = SuggestionLoader(
        debounce: const Duration(milliseconds: 10),
        fetch: (query) =>
            (bekleyenler[query] = Completer<List<String>>()).future,
      );
      addTearDown(loader.dispose);

      var sonuc = <String>[];
      loader.request('a', (r) => sonuc = r);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      loader.request('ab', (r) => sonuc = r);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      bekleyenler['ab']!.complete(['ab sonucu']);
      await Future<void>.delayed(Duration.zero);
      bekleyenler['a']!.complete(['a sonucu']);
      await Future<void>.delayed(Duration.zero);

      expect(sonuc, ['ab sonucu'],
          reason: 'eskimiş yanıt kullanıcının yazdığıyla alakasız');
    });

    test('ağ hatasında sessizce geçilir', () async {
      var cagrildi = false;
      final loader = SuggestionLoader(
        debounce: const Duration(milliseconds: 10),
        fetch: (query) async => throw Exception('ağ yok'),
      );
      addTearDown(loader.dispose);

      loader.request('lofi', (_) => cagrildi = true);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(cagrildi, isFalse,
          reason: 'öneri gelmemesi kullanıcıya hata olarak gösterilmemeli');
    });

    test('sorgu silinince öneriler hemen boşalır', () async {
      final loader = SuggestionLoader(
        debounce: const Duration(milliseconds: 10),
        fetch: (query) async => ['bir şey'],
      );
      addTearDown(loader.dispose);

      List<String>? sonuc;
      loader.request('', (r) => sonuc = r);

      expect(sonuc, isEmpty, reason: 'boş sorguda uzak öneri istenmez');
    });
  });
}
