import '../extraction/models.dart';

/// İçeriğin dinlenmek mi yoksa izlenmek mi için olduğu.
enum ContentKind {
  /// Müzik/podcast tarzı: varsayılan olarak sesli modda açılır.
  music,

  /// İzlenmesi gereken içerik: varsayılan olarak video modunda açılır.
  video,
}

/// YouTube'un kendi kategori etiketi en güvenilir sinyal; yoksa başlık ve
/// etiketlerden çıkarım yapılır.
///
/// Bu yalnızca AÇILIŞ modunu belirler — kullanıcı her zaman elle
/// değiştirebilir ve seçtiği mod kendiliğinden geri dönmez.
ContentKind detectContentKind(VideoDetails details) {
  final category = details.category?.toLowerCase().trim();
  if (category != null && category.isNotEmpty) {
    if (category == 'music' || category == 'müzik') return ContentKind.music;
    return ContentKind.video;
  }

  final haystack = [
    details.title.toLowerCase(),
    ...details.tags.map((t) => t.toLowerCase()),
  ].join(' ');

  const musicHints = [
    'official audio',
    'official music video',
    'lyrics',
    'lyric video',
    'full album',
    'albüm',
    'soundtrack',
    'podcast',
    'radio',
    'mix',
    'playlist',
    'beats',
    'song',
    'şarkı',
    'müzik',
  ];

  if (musicHints.any(haystack.contains)) return ContentKind.music;
  return ContentKind.video;
}
