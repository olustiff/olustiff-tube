import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:olustiff/core/data/library_store.dart';
import 'package:olustiff/core/ui/tv_mode.dart';
import 'package:olustiff/features/search/search_screen.dart';
import 'package:olustiff/features/search/tv_keyboard.dart';
import 'package:olustiff/features/search/tv_search_screen.dart';

Map<String, Object?> videoMap(String id, String title) => {
      'videoId': id,
      'title': title,
      'url': 'https://www.youtube.com/watch?v=$id',
      'uploaderName': 'Kanal',
      'durationSeconds': 120,
      'viewCount': 10,
      'textualUploadDate': null,
      'thumbnailUrl': null,
    };

void main() {
  group('TvKeyboardLayout', () {
    final layout = TvKeyboardLayout.turkish();

    test('harf ızgarası 6 sütun, harfler ve rakamlar tam oturur', () {
      // Son satır eylem tuşları; öncesi harf/rakam ızgarası.
      final gridRows = layout.rows.sublist(0, layout.rows.length - 1);

      expect(gridRows, hasLength(7));
      for (final row in gridRows) {
        expect(row, hasLength(TvKeyboardLayout.columns));
      }

      final harfler = gridRows
          .expand((row) => row)
          .map((key) => key.value)
          .join();
      expect(harfler, TvKeyboardLayout.alphabet,
          reason: 'ızgarada eksik/artık tuş kalmamalı');
    });

    test('Türkçe harfler ve rakamlar ızgarada var', () {
      final harfler = layout.rows
          .expand((row) => row)
          .map((key) => key.value)
          .whereType<String>()
          .toSet();

      for (final harf in ['ç', 'ğ', 'ı', 'ö', 'ş', 'ü']) {
        expect(harfler, contains(harf), reason: 'Türkçe yazılamıyordu');
      }
      for (final rakam in ['0', '5', '9']) {
        expect(harfler, contains(rakam));
      }
      // Yabancı şarkı adları için gerekli.
      for (final harf in ['q', 'w', 'x']) {
        expect(harfler, contains(harf));
      }
    });

    test('eylem satırında boşluk, sil, temizle, ara ve mikrofon bulunur', () {
      final actions = layout.rows.last.map((key) => key.kind).toList();

      expect(actions, [
        TvKeyKind.space,
        TvKeyKind.backspace,
        TvKeyKind.clear,
        TvKeyKind.search,
        TvKeyKind.voice,
      ]);
    });

    test('ses tanıma yoksa mikrofon tuşu hiç çizilmez', () {
      final sessiz = TvKeyboardLayout.turkish(withVoice: false);
      final actions = sessiz.rows.last.map((key) => key.kind).toList();

      expect(actions, isNot(contains(TvKeyKind.voice)),
          reason: 'basınca bir şey olmayan tuş kullanıcıyı yanıltır');
      // Eylem satırı yine 6 sütunu doldurur: "Ara" genişleyerek kapatır.
      expect(
        sessiz.rows.last.fold<int>(0, (sum, key) => sum + key.span),
        TvKeyboardLayout.columns,
      );
    });
  });

  group('TvKeyboardLayout gezinme', () {
    final layout = TvKeyboardLayout.turkish();

    test('sağ kenardan sağa basmak ızgaradan çıkar', () {
      expect(layout.move(const TvKeyPosition(0, 5), TraversalDirection.right),
          isNull,
          reason: 'ekran o zaman odağı sağdaki sonuç listesine taşıyor');
      expect(layout.move(const TvKeyPosition(0, 4), TraversalDirection.right),
          const TvKeyPosition(0, 5));
    });

    test('sol kenardan sola basmak ızgarada kalır', () {
      expect(layout.move(const TvKeyPosition(3, 0), TraversalDirection.left),
          isNull);
    });

    test('aşağı/yukarı bir alt/üst satırda aynı hizaya gider', () {
      expect(layout.move(const TvKeyPosition(0, 2), TraversalDirection.down),
          const TvKeyPosition(1, 2));
      expect(layout.move(const TvKeyPosition(1, 2), TraversalDirection.up),
          const TvKeyPosition(0, 2));
      expect(layout.move(const TvKeyPosition(0, 0), TraversalDirection.up),
          isNull);
    });

    test('eylem satırına inince en yakın tuş seçilir', () {
      // "Boşluk" iki sütun geniş; son harf satırının ilk iki sütunu ona,
      // sağdaki sütunlar kendi hizalarındaki eylem tuşuna düşmeli.
      final sonHarfSatiri = layout.rows.length - 2;
      final eylemSatiri = layout.rows.length - 1;

      final soldan =
          layout.move(TvKeyPosition(sonHarfSatiri, 0), TraversalDirection.down)!;
      expect(soldan.row, eylemSatiri);
      expect(layout.keyAt(soldan).kind, TvKeyKind.space);

      final sagdan =
          layout.move(TvKeyPosition(sonHarfSatiri, 5), TraversalDirection.down)!;
      expect(layout.keyAt(sagdan).kind, TvKeyKind.voice);
    });
  });

  group('TvKeyboardLayout.apply', () {
    const harf = TvKey.character('ş');
    const bosluk = TvKey.action(TvKeyKind.space, 'Boşluk');
    const sil = TvKey.action(TvKeyKind.backspace, 'Sil');
    const temizle = TvKey.action(TvKeyKind.clear, 'Temizle');
    const ara = TvKey.action(TvKeyKind.search, 'Ara');

    test('harf tuşu metnin sonuna eklenir', () {
      expect(TvKeyboardLayout.apply('ba', harf), 'baş');
    });

    test('sil son karakteri kaldırır, boş metinde bir şey yapmaz', () {
      expect(TvKeyboardLayout.apply('baş', sil), 'ba');
      expect(TvKeyboardLayout.apply('', sil), '');
    });

    test('temizle metni boşaltır', () {
      expect(TvKeyboardLayout.apply('sezen aksu', temizle), '');
    });

    test('boşluk baştayken ve üst üste eklenmez', () {
      expect(TvKeyboardLayout.apply('', bosluk), '',
          reason: 'baştaki boşluk aramayı bozuyor');
      expect(TvKeyboardLayout.apply('sezen ', bosluk), 'sezen ');
      expect(TvKeyboardLayout.apply('sezen', bosluk), 'sezen ');
    });

    test('ara tuşu metni değiştirmez', () {
      expect(TvKeyboardLayout.apply('lofi', ara), 'lofi');
    });
  });

  group('TvSearchScreen', () {
    const extractor = MethodChannel('olustiff/extractor');
    const ui = MethodChannel('olustiff/ui');
    const player = MethodChannel('olustiff/player');

    late List<String> aranan;
    late List<String> oneriIstekleri;

    Widget wrap(Widget child) => MaterialApp(home: child);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      aranan = [];
      oneriIstekleri = [];
      TvMode.isTv.value = true;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(extractor, (call) async {
        switch (call.method) {
          case 'search':
            aranan.add(call.arguments['query'] as String);
            return {
              'items': [videoMap('id0', 'Sonuç sıfır')],
              'hasMore': false,
            };
          case 'suggestions':
            oneriIstekleri.add(call.arguments['query'] as String);
            return <String>['ahmet kaya', 'aleyna tilki'];
          default:
            return null;
        }
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ui, (call) async {
        if (call.method == 'isVoiceSearchAvailable') return true;
        if (call.method == 'startVoiceSearch') return 'sezen aksu';
        return null;
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(player, (call) async => null);

      await LibraryStore.instance.load();
      await LibraryStore.instance.clearSearches();
    });

    tearDown(() {
      TvMode.isTv.value = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(extractor, null)
        ..setMockMethodCallHandler(ui, null)
        ..setMockMethodCallHandler(player, null);
    });

    // Televizyon çözünürlüğü: ızgara + sonuç listesi yan yana sığmalı.
    Future<void> tvEkrani(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('televizyonda sistem klavyesi yerine harf ızgarası açılır',
        (tester) async {
      await tvEkrani(tester);
      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(TvSearchScreen), findsOneWidget);
      expect(find.byType(TvKeyboard), findsOneWidget);
      expect(find.byType(TextField), findsNothing,
          reason: 'odaklanan metin alanı sistem klavyesini açardı');
    });

    testWidgets('sorgu boşken son aramalar sağda listelenir', (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('lofi');

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Son aramalar'), findsOneWidget);
      expect(find.text('lofi'), findsOneWidget);
    });

    testWidgets('ok tuşlarıyla gezilip OK ile metin yazılır', (tester) async {
      await tvEkrani(tester);
      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      // (0,0) = "a"
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      // (0,1) = "b"
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('ab'), findsOneWidget,
          reason: 'yazılan metin arama kutusunda görünmeli');
    });

    testWidgets('yazdıkça öneriler geçmiş + YouTube kaynağından gelir',
        (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('akşam müziği');

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      // "a" yaz.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(oneriIstekleri, ['a']);
      expect(find.text('Öneriler'), findsOneWidget);
      expect(find.text('akşam müziği'), findsOneWidget,
          reason: 'kullanıcının kendi geçmişi önce gelmeli');
      expect(find.text('ahmet kaya'), findsOneWidget,
          reason: 'YouTube otomatik tamamlaması da listelenmeli');
    });

    testWidgets('sağa basınca odak önerilere geçer, OK arama yapar',
        (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('lofi');

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      // Izgaranın sağ kenarına git, bir kez daha sağa basınca listeye geç.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(aranan, ['lofi']);
      expect(LibraryStore.instance.searches, contains('lofi'));
      expect(find.text('Sonuç sıfır'), findsOneWidget);
    });

    testWidgets('geçmiş satırı kumandayla seçilip OK ile aranır',
        (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('lofi');
      await LibraryStore.instance.recordSearch('sezen aksu');

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      // Izgaradan listeye geç (en sağdan bir kez daha sağa).
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      // İkinci geçmiş kaydına in.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(aranan, ['lofi'],
          reason: 'en son arama başta olur; bir aşağısı "lofi"');
    });

    testWidgets('geçmiş satırından sağ ok ile kaldır düğmesine geçilir',
        (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('lofi');

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      // Seçili geçmiş satırında silmenin nasıl yapılacağı yazıyor.
      expect(find.text('Kaldırmak için ▶'), findsOneWidget);

      // Sağ ok kaldır düğmesine geçer, OK siler.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(LibraryStore.instance.searches, isNot(contains('lofi')));
      expect(aranan, isEmpty,
          reason: 'kaldır düğmesindeyken OK arama yapmamalı');
    });

    testWidgets('kaldır düğmesindeyken sol ok satıra geri döner',
        (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('lofi');

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(LibraryStore.instance.searches, contains('lofi'),
          reason: 'sol ok satıra döndürmeliydi, silme olmamalı');
      expect(aranan, ['lofi']);
    });

    testWidgets('YouTube önerisinde kaldır düğmesi bulunmaz', (tester) async {
      await tvEkrani(tester);

      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      // "a" yaz: liste uzak önerilerle dolsun (geçmiş boş).
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Kaldırmak için ▶'), findsNothing);
      expect(aranan, ['ahmet kaya'],
          reason: 'uzak öneride sağ ok bir şeyi değiştirmemeli, OK aramalı');
    });

    testWidgets('mikrofon tuşu ses tanımayı çağırır ve sonucu arar',
        (tester) async {
      await tvEkrani(tester);
      await tester.pumpWidget(wrap(const SearchScreen()));
      await tester.pumpAndSettle();

      final layout = TvKeyboardLayout.turkish();
      // Mikrofon: eylem satırının son tuşu.
      for (var i = 0; i < layout.rows.length - 1; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      for (var i = 0; i < layout.rows.last.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(aranan, ['sezen aksu'],
          reason: 'konuşulan metin doğrudan aranmalı');
    });

    testWidgets('geri tuşu önce ızgaraya döner, sonra ekrandan çıkar',
        (tester) async {
      await tvEkrani(tester);
      await LibraryStore.instance.recordSearch('lofi');

      await tester.pumpWidget(wrap(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
            ),
            child: const Text('Ara'),
          ),
        ),
      ));
      await tester.tap(find.text('Ara'));
      await tester.pumpAndSettle();
      expect(find.byType(TvSearchScreen), findsOneWidget);

      // Listeye geç, geri tuşu ızgaraya döndürsün — ekran kapanmamalı.
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TvSearchScreen), findsOneWidget);

      // Izgaradayken geri ekrandan çıkarır.
      //
      // Tuş işlenmediğinde Android geri tuşunu sistem "popRoute" olarak
      // iletiyor (bkz. PopScope); gerçek cihazdaki yol bu.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TvSearchScreen), findsNothing);
    });
  });

  group('telefon arama ekranı', () {
    const extractor = MethodChannel('olustiff/extractor');
    const ui = MethodChannel('olustiff/ui');

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      TvMode.isTv.value = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(extractor, (call) async {
        if (call.method == 'suggestions') {
          return <String>['ahmet kaya'];
        }
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ui, (call) async {
        if (call.method == 'isVoiceSearchAvailable') return true;
        return null;
      });

      await LibraryStore.instance.load();
      await LibraryStore.instance.clearSearches();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(extractor, null)
        ..setMockMethodCallHandler(ui, null);
    });

    testWidgets('telefonda dokunmatik klavye ve mevcut düzen korunur',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SearchScreen()));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(TvKeyboard), findsNothing,
          reason: 'kumanda klavyesi yalnızca televizyonda kullanılmalı');
    });

    testWidgets('telefonda da yazdıkça YouTube önerileri görünür',
        (tester) async {
      await LibraryStore.instance.recordSearch('akşam müziği');

      await tester.pumpWidget(const MaterialApp(home: SearchScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Öneriler'), findsOneWidget);
      expect(find.text('akşam müziği'), findsOneWidget);
      expect(find.text('ahmet kaya'), findsOneWidget);
    });

    testWidgets('ses tanıma varsa mikrofon düğmesi gösterilir',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SearchScreen()));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.mic_none), findsOneWidget);
    });
  });
}
