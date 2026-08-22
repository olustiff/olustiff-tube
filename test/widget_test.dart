import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:akis/main.dart';

void main() {
  const channel = MethodChannel('akis/extractor');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'trending') return <Map<String, Object?>>[];
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('Ana ekran açılıyor ve arama çubuğunu gösteriyor', (tester) async {
    await tester.pumpWidget(const AkisApp());
    await tester.pumpAndSettle();

    expect(find.text('Video ara...'), findsOneWidget);
    expect(find.text('Sonuç bulunamadı.'), findsOneWidget);
  });
}
