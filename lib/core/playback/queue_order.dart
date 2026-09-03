/// Kuyruğun GERÇEK çalma sırasıyla ilgili hesaplar.
///
/// Ayrı bir dosya çünkü buradaki tek soru — "sırada gerçekte ne var?" —
/// arayüzün en çok yanıldığı yerdi ve testle sabitlenmesi gerekiyor.
///
/// Karıştırma açıkken çalma sırası kuyruğun kendi sırası DEĞİL: native taraf
/// ayrı bir indeks listesi tutuyor ve oynatmayı ona göre ilerletiyor. Arayüz
/// kuyruğu ham sırasıyla gösterdiğinde kullanıcıya çalmayacak bir videoyu
/// "sıradaki" diye gösteriyordu.
library;

/// Çalanın ardından gelecek kuyruk indeksleri, çalma sırasına göre.
///
/// [order] native'in bildirdiği çalma sırası (kuyruk indeksleri). Boş gelirse
/// —henüz bildirilmediyse ya da eski bir sürüm konuşuyorsa— kuyruğun kendi
/// sırası kullanılıyor; bu, karıştırma kapalıyken zaten doğru cevap.
///
/// [current] o an çalanın kuyruktaki indeksi. Sıranın içinde bulunamazsa
/// (kuyruk yeni değişmiş olabilir) baştan itibaren tüm sıra döner: kullanıcıya
/// boş bir liste göstermektense sıradakileri göstermek doğru.
///
/// Aralık dışı ve tekrar eden indeksler ayıklanıyor — bunlar kuyruk ile sıranın
/// bir an için uyuşmadığı geçiş anlarında gerçekten geliyor ve ayıklanmazsa
/// arayüz çökerdi.
List<int> upcomingQueueIndexes({
  required List<int> order,
  required int current,
  required int queueLength,
}) {
  if (queueLength <= 0) return const [];

  final effective = order.isEmpty
      ? List<int>.generate(queueLength, (i) => i)
      : order;

  final seen = <int>{};
  final cleaned = <int>[];
  for (final index in effective) {
    if (index < 0 || index >= queueLength) continue;
    if (!seen.add(index)) continue;
    cleaned.add(index);
  }

  final at = cleaned.indexOf(current);
  if (at == -1) return List.unmodifiable(cleaned);
  return List.unmodifiable(cleaned.sublist(at + 1));
}
