import '../extraction/models.dart';

/// Bir metnin ağırlıklı olarak hangi yazı sisteminde olduğu.
///
/// Dil tespiti için en ucuz ve en güvenilir sinyal: "Saraiki", Hintçe veya
/// Korece bir şarkı, Türkçe/İngilizce dinleyen birinin kuyruğuna girmemeli.
enum TextScript { latin, cyrillic, arabic, devanagari, cjk, greek, hebrew, other }

TextScript detectScript(String text) {
  final counts = <TextScript, int>{};
  for (final rune in text.runes) {
    final script = _scriptOf(rune);
    if (script == null) continue;
    counts[script] = (counts[script] ?? 0) + 1;
  }
  if (counts.isEmpty) return TextScript.other;
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

/// Metinde geçen TÜM yazı sistemleri.
///
/// Yalnızca baskın olana bakmak yetmiyor: "ZALIM WADERA | Saraiki गीत" gibi
/// başlıklarda çoğunluk Latin olsa da birkaç Devanagari harf içeriğin dilini
/// ele veriyor.
Set<TextScript> scriptsIn(String text) {
  final scripts = <TextScript>{};
  for (final rune in text.runes) {
    final script = _scriptOf(rune);
    if (script != null) scripts.add(script);
  }
  return scripts;
}

TextScript? _scriptOf(int rune) {
  // Sayı, noktalama ve emoji sinyal taşımaz.
  if (rune < 0x0041) return null;
  if (rune <= 0x024F) return TextScript.latin; // Latin + ek harfler (ş, ğ, é…)
  if (rune >= 0x0370 && rune <= 0x03FF) return TextScript.greek;
  if (rune >= 0x0400 && rune <= 0x04FF) return TextScript.cyrillic;
  if (rune >= 0x0590 && rune <= 0x05FF) return TextScript.hebrew;
  if (rune >= 0x0600 && rune <= 0x06FF) return TextScript.arabic;
  if (rune >= 0x0900 && rune <= 0x097F) return TextScript.devanagari;
  if (rune >= 0x3040 && rune <= 0x9FFF) return TextScript.cjk;
  if (rune >= 0xAC00 && rune <= 0xD7AF) return TextScript.cjk; // Hangul
  return null;
}

/// Başlıklarda sık geçen ve benzerlik taşımayan kelimeler.
const _stopWords = {
  'official', 'video', 'music', 'audio', 'lyrics', 'lyric', 'hd', 'hq', '4k',
  'remix', 'feat', 'ft', 'the', 'a', 'and', 've', 'ile', 'mv', 'm/v', 'full',
  'new', 'yeni', 'klip',
};

/// Bir parçanın "sürüm" işaretleri: aynı şarkının farklı çekimlerini
/// adlandıran kelimeler.
///
/// [trackCore] bunları atıyor ki "La Câlin" ile "La Câlin (Slowed + Reverb)"
/// aynı parça sayılabilsin.
const _versionWords = {
  'slowed', 'reverb', 'sped', 'speed', 'nightcore', 'cover', 'karaoke',
  'acoustic', 'akustik', 'live', 'canli', 'version', 'versiyon', 'edit',
  'instrumental', 'enstrumantal', 'bass', 'boosted', 'extended', 'radio',
  'hizlandirilmis', 'yavaslatilmis', 'tiktok', 'visualizer', 'clip',
};

/// Başlığın "hangi parça" çekirdeği.
///
/// İki aşama var ve ilki belirleyici:
///
/// 1. **Başlık ilk AYRAÇTA kesiliyor.** Gerçek cihazda görüldü: aynı şarkının
///    sürümleri tam da orada ayrışıyor — "La Câlin **(Obiymy)**",
///    "La Câlin **| TARVYN Remix**", "La Câlin **// Escaping the Ripper**".
///    Ayraç öncesi kısım hepsinde aynı. Buna karşılık gerçekten farklı bir
///    şarkı olan "Поле мечты" ayraç taşımıyor ve "Поле"den ayrışmaya devam
///    ediyor. Kelime kesişimine bakan ölçütler bu ikisini ayıramıyordu.
/// 2. Kalan kısımdan sürüm ve süs kelimeleri atılıyor — ayraçsız yazılmış
///    "Sarki Remix" gibi başlıklar için.
///
/// Sayılar KORUNUYOR; kelime uzunluğu eşiğine takılmıyorlar. Bu şart:
/// "57. Bölüm" ile "58. Bölüm" yalnızca sayıda ayrışıyor, sayı atılsaydı
/// bütün bölümler aynı parça sayılır ve dizi kuyruğu tek bölüme inerdi.
///
/// Kesme İKİ durumda uygulanmıyor, ikisi de gerçek başlıklardan:
/// - Ayraç sonrası sayı taşıyorsa: "Kuruluş Osman | 57. Bölüm" ile
///   "| 60. Bölüm" kesilince ikisi de {kurulus, osman} oluyor ve bütün
///   bölümler aynı parça sayılıyordu.
/// - Ayraç öncesi tek kelimeye iniyorsa: "BTS (방탄소년단) 'Dynamite'" ve
///   "BTS (방탄소년단) 'Butter'" ikisi de {bts} oluyordu — tek kelime bir
///   parçayı değil, sanatçıyı adlandırıyor.
Set<String> trackCore(String title) {
  final head = _beforeSeparator(title);
  if (head == title) return _coreWords(title);
  final tail = title.substring(head.length);
  // Kelime sayısı süzmeden ÖNCE sayılıyor: "La Câlin"in "la"sı çekirdeğe
  // girmiyor ama başlığın tek kelimelik bir sanatçı adı olmadığını gösteriyor.
  final headWords = head
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty);
  if (tail.contains(RegExp(r'\d')) || headWords.length < 2) {
    return _coreWords(title);
  }
  return _coreWords(head);
}

Set<String> _coreWords(String text) => _foldAccents(text)
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((w) => w.isNotEmpty)
    .where((w) => w.length > 2 || int.tryParse(w) != null)
    .where((w) => !_stopWords.contains(w) && !_versionWords.contains(w))
    .toSet();

/// Küçük harfe çevirir ve aksanları düşürür.
///
/// Aynı şarkı iki yazımla birden dolaşıyor: cihazda hem "La Câlin" hem
/// "La Calin" aynı arama sonucunda çıktı. Aksan düşürülmezse bunlar farklı
/// parça sayılıyor ve ikisi de kuyruğa giriyordu.
String _foldAccents(String text) {
  const from = 'âàäáãçğıíìïîñöóòôõşüúùûýÿéèëê';
  const to = 'aaaaacgiiiiinooooosuuuuyyeeee';
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final index = from.indexOf(char);
    buffer.write(index == -1 ? char : to[index]);
  }
  return buffer.toString();
}

/// Başlığın ilk ayraçtan önceki kısmı.
///
/// Ayraç hiç yoksa başlık olduğu gibi dönüyor. Kesilen kısım başlığın
/// TAMAMINI götürüyorsa (ör. "(Official Video)" ile başlayan başlıklar)
/// kesme uygulanmıyor — boş bir çekirdek hiçbir şeyle karşılaştırılamaz.
String _beforeSeparator(String title) {
  final cut = title.indexOf(RegExp(r'[(\[{|/«]'));
  if (cut <= 0) return title;
  final head = title.substring(0, cut).trim();
  return head.isEmpty ? title : head;
}

/// İki kayıt AYNI parçanın farklı sürümü mü.
///
/// Neden gerekiyor: kuyruk benzerliğe göre kuruluyor ve bir şarkının remiksi
/// o şarkıya EN ÇOK benzeyen şey. Gerçek kullanımda kuyruk baştan sona aynı
/// şarkının remiks/hızlandırılmış/kapak sürümleriyle doluyordu — kullanıcının
/// istediği şey bu değil.
///
/// Ölçüt eşitlik, kapsama DEĞİL: "Поле" ile "Поле мечты" farklı şarkılar ve
/// kapsama ölçütü ikincisini yanlışlıkla eler.
bool isSameTrack(String a, String b) {
  final left = trackCore(a);
  final right = trackCore(b);
  if (left.isEmpty || right.isEmpty) return false;
  return left.length == right.length && left.containsAll(right);
}

Set<String> _keywords(String text) {
  return text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.length > 2 && !_stopWords.contains(w))
      .toSet();
}

/// [candidate]'ın [seed]'e ne kadar benzediği. Yüksek = daha benzer.
///
/// Amaç kuyruğun "radyo" gibi akması: aynı dil ve yakın tarz. Tamamen
/// alakasız içerik kuyruğa girerse kullanıcı sıkılır.
int similarityScore(VideoSummary seed, VideoSummary candidate) {
  var score = 0;

  final seedText = '${seed.title} ${seed.uploaderName ?? ''}';
  final candidateText = '${candidate.title} ${candidate.uploaderName ?? ''}';

  final seedScripts = scriptsIn(seedText);
  final candidateScripts = scriptsIn(candidateText);

  // Adayda, çalan içerikte hiç geçmeyen bir yazı sistemi varsa büyük
  // olasılıkla farklı dilde bir içerik.
  final foreign = candidateScripts.difference(seedScripts);
  if (foreign.isNotEmpty) {
    score -= 8;
  } else if (detectScript(seedText) == detectScript(candidateText)) {
    score += 4;
  }

  // Aynı sanatçı/kanal güçlü bir tarz sinyali.
  final seedChannel = seed.uploaderName?.toLowerCase();
  final candidateChannel = candidate.uploaderName?.toLowerCase();
  if (seedChannel != null && seedChannel == candidateChannel) score += 3;

  // Başlık ve kanal adındaki ortak anlamlı kelimeler.
  final seedWords = _keywords('${seed.title} ${seed.uploaderName ?? ''}');
  final candidateWords =
      _keywords('${candidate.title} ${candidate.uploaderName ?? ''}');
  score += seedWords.intersection(candidateWords).length * 2;

  // Süre yakınlığı: 3 dakikalık bir şarkının ardından 1 saatlik mix gelmesi
  // dinleme akışını bozar.
  final seedDuration = seed.durationSeconds;
  final candidateDuration = candidate.durationSeconds;
  if (seedDuration > 0 && candidateDuration > 0) {
    final ratio = candidateDuration > seedDuration
        ? candidateDuration / seedDuration
        : seedDuration / candidateDuration;
    if (ratio <= 1.5) {
      score += 2;
    } else if (ratio >= 4) {
      // 3 dakikalık şarkının ardından saatlik bir mix gelmesi akışı bozar;
      // aynı dilde olsa bile kuyruğa girmemeli.
      score -= 6;
    }
  }

  return score;
}
