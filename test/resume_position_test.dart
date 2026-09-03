import 'package:flutter_test/flutter_test.dart';
import 'package:olustiff/core/data/library_store.dart';
import 'package:olustiff/core/extraction/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

VideoSummary _video(String id) => VideoSummary(
      videoId: id,
      title: 'Bölüm $id',
      url: 'https://youtu.be/$id',
      uploaderName: 'Kanal',
      durationSeconds: 3600,
      viewCount: 0,
      textualUploadDate: null,
      thumbnailUrl: null,
    );

void main() {
  late LibraryStore store;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    store = LibraryStore.instance;
    await store.load();
    // Singleton: testler arasında geçmiş sızmasın.
    await store.clearWatched();
  });

  group('kaldığın yer', () {
    test('ortasında bırakılan video kaydedilir', () async {
      await store.recordPosition('abc', 600000, 3600000);
      expect(store.positionOf('abc'), 600000);
    });

    // Videoyu daha yeni açmış: "devam et" ona bir şey kazandırmaz, üstelik
    // geçmiş yarım kalmış videolarla dolar.
    test('başa çok yakın konum kaydedilmez', () async {
      await store.recordPosition('abc', 5000, 3600000);
      expect(store.positionOf('abc'), 0);
    });

    // Bitmiş sayılır: bir dahaki açılışta son saniyeye atlayıp hemen bitmesi
    // hata gibi görünürdü.
    test('sona çok yakın konum kaydedilmez', () async {
      await store.recordPosition('abc', 3590000, 3600000);
      expect(store.positionOf('abc'), 0);
    });

    test('sonuna gelince daha önceki kayıt silinir', () async {
      await store.recordPosition('abc', 600000, 3600000);
      await store.recordPosition('abc', 3595000, 3600000);
      expect(store.positionOf('abc'), 0);
    });

    // Canlı yayında ya da süre henüz okunmadığında sona göre karar
    // verilemez; yalnızca alt eşik uygulanır.
    test('süre bilinmiyorsa yalnızca alt eşik uygulanır', () async {
      await store.recordPosition('abc', 600000, null);
      expect(store.positionOf('abc'), 600000);
      await store.recordPosition('xyz', 5000, null);
      expect(store.positionOf('xyz'), 0);
    });

    test('hiç bilinmeyen video sıfır döner', () {
      expect(store.positionOf('bilinmeyen'), 0);
    });
  });

  group('yarım kalanlar listesi', () {
    test('yalnızca konumu olan izlenmişler, en son önce', () async {
      await store.recordWatch(_video('eski'));
      await store.recordWatch(_video('yeni'));
      await store.recordPosition('eski', 600000, 3600000);
      await store.recordPosition('yeni', 900000, 3600000);

      expect(store.resumable.map((v) => v.videoId), ['yeni', 'eski']);
    });

    test('konumu olmayan izlenmişler listeye girmez', () async {
      await store.recordWatch(_video('tamamlanan'));
      expect(store.resumable, isEmpty);
    });

    test('geçmiş temizlenince konumlar da gider', () async {
      await store.recordWatch(_video('abc'));
      await store.recordPosition('abc', 600000, 3600000);
      await store.clearWatched();
      expect(store.positionOf('abc'), 0);
      expect(store.resumable, isEmpty);
    });
  });
}
