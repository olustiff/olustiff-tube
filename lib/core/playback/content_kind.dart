import '../extraction/models.dart';

/// İçeriğin dinlenmek mi yoksa izlenmek mi için olduğu.
enum ContentKind {
  /// Müzik/podcast tarzı: varsayılan olarak sesli modda açılır.
  music,

  /// İzlenmesi gereken içerik: varsayılan olarak video modunda açılır.
  video,
}

/// YouTube'un kendi kategori etiketi en güvenilir sinyal; başlık ve etiketler
/// onu tamamlıyor.
///
/// Bu yalnızca AÇILIŞ modunu belirler — kullanıcı her zaman elle
/// değiştirebilir ve seçtiği mod kendiliğinden geri dönmez.
///
/// ## Kategori neden tek başına yetmiyor
///
/// Kategori bir zamanlar mutlak kabul ediliyordu: "Music" değilse video.
/// Gerçek kullanımda bu, müzik dinleyen birine sürekli video indirtiyordu —
/// hayran derlemeleri ("ВСЕ ТРЕКИ", "лучшие треки", "Official Audio")
/// YouTube'a çoğu zaman "Entertainment" ya da "People & Blogs" olarak
/// yükleniyor. Kategoriye takılıp başlığa hiç bakmamak bu içeriği izlenecek
/// video sayıyordu.
///
/// Bu yüzden ipuçları İKİYE ayrıldı:
/// - **Güçlü ipuçları** tek başlarına yeterli; kategori ne derse desin
///   geçerliler, çünkü başka türlü okunmaları mümkün değil ("official audio",
///   "full album", "все треки").
/// - **Zayıf ipuçları** yalnızca kategori HİÇ yoksa kullanılıyor. "mix",
///   "radio", "playlist" gibi kelimeler bir oyun videosunun başlığında da
///   geçiyor; açık bir kategori varken onu ezmeleri yanlış olurdu.
ContentKind detectContentKind(VideoDetails details) {
  final category = details.category?.toLowerCase().trim();
  final hasCategory = category != null && category.isNotEmpty;
  if (hasCategory && (category == 'music' || category == 'müzik')) {
    return ContentKind.music;
  }

  final haystack = [
    details.title.toLowerCase(),
    ...details.tags.map((t) => t.toLowerCase()),
  ].join(' ');

  if (_strongMusicHints.any(haystack.contains)) return ContentKind.music;
  if (!hasCategory && _weakMusicHints.any(haystack.contains)) {
    return ContentKind.music;
  }
  return ContentKind.video;
}

/// Başka türlü okunması mümkün olmayan ipuçları; kategoriyi ezerler.
const _strongMusicHints = [
  'official audio',
  'official music video',
  'lyrics',
  'lyric video',
  'full album',
  'albüm',
  'soundtrack',
  'podcast',
  'şarkı',
  'müzik',
  // Rusça/Ukraynaca: kullanıcının kütüphanesinin büyük kısmı bu dilde ve
  // hiçbiri eski listede yoktu.
  'треки',
  'песни',
  'песня',
  'музыка',
  'сборник',
  'альбом',
];

/// Tek başlarına yetmeyen ipuçları; yalnızca kategori yoksa bakılır.
const _weakMusicHints = [
  'radio',
  'mix',
  'playlist',
  'beats',
  'song',
];
