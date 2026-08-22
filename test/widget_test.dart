import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:akis/core/data/library_store.dart';
import 'package:akis/core/data/settings_store.dart';
import 'package:akis/features/home/home_screen.dart';
import 'package:akis/features/search/search_screen.dart';

Map<String, Object?> videoMap(String id, String title, {String? uploader}) => {
      'videoId': id,
      'title': title,
      'url': 'https://www.youtube.com/watch?v=$id',
      'uploaderName': uploader ?? 'Kanal',
      'durationSeconds': 120,
      'viewCount': 10,
      'textualUploadDate': null,
      'thumbnailUrl': null,
    };

void main() {
  const extractor = MethodChannel('akis/extractor');
  const player = MethodChannel('akis/player');

  late int loadMoreCalls;

  Widget wrap(Widget child) => MaterialApp(home: child);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    loadMoreCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(extractor, (call) async {
      switch (call.method) {
        case 'search':
          return {
            'items': [
              for (var i = 0; i < 20; i++)
                videoMap('id$i', 'Sonuç $i'),
            ],
            'hasMore': true,
          };
        case 'loadMore':
          loadMoreCalls++;
          return {
            'items': [
              for (var i = 20; i < 40; i++) videoMap('id$i', 'Sonuç $i'),
            ],
            'hasMore': false,
          };
        default:
          return null;
      }
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(player, (call) async => null);

    await LibraryStore.instance.load();
    await SettingsStore.instance.load();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(extractor, null)
      ..setMockMethodCallHandler(player, null);
  });

  testWidgets('geçmiş boşken ana ekran kullanıcıyı aramaya yönlendirir',
      (tester) async {
    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Aramaya başla'), findsOneWidget,
        reason: 'trend listesi yerine kişisel akış boş durumu gösterilmeli');
  });

  testWidgets('arama yapılınca geçmişe kaydedilir', (tester) async {
    await tester.pumpWidget(wrap(const SearchScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'selena gomez');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(LibraryStore.instance.searches, contains('selena gomez'));
    expect(find.text('Sonuç 0'), findsOneWidget);
  });

  testWidgets('arama sonuçlarında sonsuz kaydırma devam sayfası yükler',
      (tester) async {
    await tester.pumpWidget(wrap(const SearchScreen(initialQuery: 'jazz')));
    await tester.pumpAndSettle();

    expect(loadMoreCalls, 0);

    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    expect(loadMoreCalls, greaterThan(0),
        reason: 'sonuçlar ~20 ile sınırlı kalmamalı');

    await tester.drag(find.byType(ListView), const Offset(0, -8000));
    await tester.pumpAndSettle();

    expect(find.text('Sonuç 39'), findsOneWidget);
  });

  testWidgets('boş arama ekranı son aramaları önerir', (tester) async {
    await LibraryStore.instance.recordSearch('lofi');

    await tester.pumpWidget(wrap(const SearchScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Son aramalar'), findsOneWidget);
    expect(find.text('lofi'), findsOneWidget);
  });
}
