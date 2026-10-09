import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';

import '../cast/cast_controller.dart';
import '../cast/cast_protocol.dart';
import '../data/library_store.dart';
import '../data/settings_store.dart';
import '../extraction/extraction_client.dart';
import '../extraction/models.dart';
import '../ui/tv_mode.dart';
import 'content_kind.dart';
import 'playback_client.dart';
import 'queue_builder.dart';
import 'queue_order.dart';
import 'stream_selection.dart';

/// "Ne çalıyor, sırada ne var" bilgisinin Dart tarafındaki yüzü.
///
/// Önemli: kuyruk ve otomatik geçiş NATIVE tarafta yaşar
/// (`PlaybackQueue` / `PlayerHolder`). Sebep: ekran kapandığında Flutter motoru
/// askıya alınır ve Dart kodu çalışmaz — geçiş burada olsaydı hiç tetiklenmezdi.
/// Bu sınıf yalnızca kuyruğu kurar ve arayüzün ihtiyaç duyduğu meta veriyi
/// tutar.
class PlaybackCoordinator extends ChangeNotifier {
  PlaybackCoordinator._();

  static final PlaybackCoordinator instance = PlaybackCoordinator._();

  final _extraction = ExtractionClient();
  final _playback = PlaybackClient.shared;
  final _library = LibraryStore.instance;
  final _settings = SettingsStore.instance;

  VideoDetails? _details;
  bool _audioOnly = false;
  String? _qualityLabel;
  List<VideoSummary> _queue = const [];
  int _index = -1;

  /// Native'in bildirdiği gerçek çalma sırası (kuyruk indeksleri).
  ///
  /// Karıştırma açıkken kuyruğun kendi sırasından FARKLI. Arayüz "sırada"
  /// listesini bundan diziyor; ham kuyruğu göstermek, çalmayacak bir videoyu
  /// sıradaki diye göstermek demekti.
  List<int> _playOrder = const [];

  /// Çalanın ardından gelecekler — gerçekten çalınacak sırayla.
  ///
  /// Kuyruktaki indeksle birlikte dönüyor: arayüz bir satıra dokunulduğunda
  /// hangi indekse atlayacağını bilmek zorunda ve karıştırmada bu, listedeki
  /// konumla aynı değil.
  List<({int index, VideoSummary video})> get upcoming => [
        for (final index in upcomingQueueIndexes(
          order: _playOrder,
          current: _index,
          queueLength: _queue.length,
        ))
          (index: index, video: _queue[index]),
      ];

  QueueMode _queueMode = QueueMode.mixed;

  QueueMode get queueMode => _queueMode;

  /// Yeni bir medya hazırlanıyor mu. Arayüz bu sürede eski videonun karesini
  /// göstermek yerine yükleme durumuna geçer.
  bool _loading = false;
  bool get isLoading => _loading;

  /// Her oynatma isteğine verilen sıra numarası.
  ///
  /// Çözümleme ağdan geldiği için saniyeler sürebiliyor. Kullanıcı bu sırada
  /// başka bir videoya geçerse ÖNCEKİ isteğin geç dönen sonucu yenisinin
  /// üstüne yazıyordu: ekranda eski başlık/kapak beliriyor, hatta yanlış
  /// medya çalmaya başlıyordu. Sonuç yazılmadan önce jetonun hâlâ güncel
  /// olduğu doğrulanır; eski istek sessizce terk edilir.
  int _requestId = 0;

  /// Şu an çalan ya da hazırlanmakta olan videonun kimliği.
  ///
  /// Yalnızca `_details`e bakmak yetmiyordu: oynatma ekranı, çözümleme daha
  /// bitmeden açıldığı için "bu video çalmıyor" sanıp İKİNCİ bir oynatma
  /// isteği başlatıyordu. İkinci istek, dokunulan listeyi taşımadığı için
  /// kuyruk da yanlış kuruluyordu.
  String? _targetVideoId;

  /// Meta verisi alınamayan parça. Durum akışı saniyede birkaç kez geldiği
  /// için, başarısız denemeyi hatırlamazsak aynı istek ağ kopukken sürekli
  /// tekrarlanırdı.
  String? _syncFailedFor;

  /// Son hazırlığın hatası. Oynatma isteği çoğu zaman `await` edilmeden
  /// başlatılıp ekran hemen açılıyor; hata burada tutulmazsa oynatma ekranı
  /// hiç haber alamaz ve sonsuza kadar "hazırlanıyor"da kalırdı.
  Object? _lastError;

  Object? get lastError => _lastError;

  /// Hazırlanırken gösterilecek özet (başlık/kapak). Tam detay gelene kadar
  /// ekran boş kalmasın diye kuyruktan alınır.
  VideoSummary? _pending;
  VideoSummary? get pending => _pending;

  VideoDetails? get details => _details;
  bool get audioOnly => _audioOnly;
  /// Kalite rozetinde gösterilecek metin; bilinmiyorsa null.
  ///
  /// Sesli modda HER ZAMAN "Sadece ses" döner. Gerekli, çünkü kuyruk native
  /// tarafça ilerletildiğinde etiket sıfırlanıyor ve arayüz ayardaki değere
  /// ("Otomatik") düşüyordu: ekranda kulaklık simgesi ve "Dinleniyor" yazarken
  /// rozet "Otomatik" diyordu. Gerçek cihazda görüldü ve kullanıcıyı haklı
  /// olarak şaşırttı.
  String? get qualityLabel =>
      resolveQualityLabel(audioOnly: _audioOnly, label: _qualityLabel);
  bool get hasMedia => _details != null;
  List<VideoSummary> get queue => List.unmodifiable(_queue);
  int get queueIndex => _index;

  /// Bu video çalıyor mu ya da onun için hazırlık sürüyor mu.
  bool isCurrent(String videoId) =>
      _details?.videoId == videoId || _targetVideoId == videoId;

  /// Sıradaki video — GERÇEK çalma sırasına göre.
  ///
  /// `_index + 1` demek karıştırma açıkken yanlış cevap veriyordu: ekranda
  /// "Sırada: X" yazarken Y çalıyordu.
  VideoSummary? get upNext => upcoming.firstOrNull?.video;

  /// Bir videoyu çalar.
  ///
  /// [context] videonun içinden seçildiği liste (arama sonuçları, geçmiş,
  /// çalma listesi). Kuyruk buradan ve videonun ilgili videolarından
  /// karıştırılarak kurulur — böylece hep aynı sanatçı tekrarlanmaz.
  /// [forceVideo] sesli mod tespitini atlar.
  ///
  /// Telefondan yayınlanan içerik televizyonda AÇILIRKEN kullanılır: müzik
  /// içeriği telefonda bilerek sesli modda açılıyor, ama televizyonda ekran
  /// zaten karşıda — orada sesli mod diye bir senaryo yok ve kullanıcı
  /// "görüntü gelmedi" diye görüyor.
  ///
  /// [startAt] verilirse video o konumdan başlar ("kaldığın yerden devam").
  /// Verilmezse baştan başlar — çağıranın açıkça istemesi gerekiyor, çünkü
  /// kullanıcı bir videoyu yeniden açtığında her zaman kaldığı yeri istemiyor
  /// (aramadan yeni açılan bir video baştan başlamalı).
  Future<void> play(
    String videoId, {
    List<VideoSummary> context = const [],
    List<VideoSummary>? exactQueue,
    int? index,
    bool forceVideo = false,
    Duration? startAt,
  }) async {
    final requestId = ++_requestId;
    _targetVideoId = videoId;
    _syncFailedFor = null;
    _lastError = null;

    // Kullanıcı dokunur dokunmaz arayüz tepki versin: eski videonun karesi
    // ekranda kalmasın, yeni içeriğin başlığı hemen görünsün.
    _loading = true;
    _pending = [...context, ...(exactQueue ?? const <VideoSummary>[])]
        .where((v) => v.videoId == videoId)
        .firstOrNull;
    _details = null;
    notifyListeners();

    try {
      await _play(
        videoId,
        context,
        exactQueue,
        index,
        requestId,
        forceVideo,
        startAt,
      );
    } catch (e) {
      // Hazırlık başarısız oldu: hedefi bırak ki kullanıcı aynı videoya
      // yeniden dokunduğunda tekrar denensin. Hata fırlatılmıyor — çağıranlar
      // beklemiyor; ekran hatayı [lastError]'dan okuyup gösteriyor.
      if (requestId == _requestId) {
        _targetVideoId = null;
        _lastError = e;
      }
    } finally {
      // Daha yeni bir istek başladıysa yükleme durumunu artık O yönetiyor;
      // buradan sıfırlamak yeni videonun yükleniyor göstergesini düşürürdü.
      if (requestId == _requestId) {
        _loading = false;
        _pending = null;
        notifyListeners();
      }
    }
  }

  /// Bu istek hâlâ kullanıcının istediği mi? Değilse sonucu yazmadan çık.
  bool _isStale(int requestId) => requestId != _requestId;

  Future<void> _play(
    String videoId,
    List<VideoSummary> context,
    List<VideoSummary>? exactQueue,
    int? index,
    int requestId,
    bool forceVideo,
    Duration? startAt,
  ) async {
    final details = await _extraction.videoDetails(videoId);
    if (_isStale(requestId)) return;

    final seed = _summaryOf(details);

    // YAYIN AÇIKSA oynatma televizyonda olur.
    //
    // Bu dal, oynatmanın tek giriş kapısında duruyor: listeden, kuyruktan,
    // "sırada"dan — nereden seçilirse seçilsin video televizyona gider.
    // Kontrolün telefonda, sesin televizyonda olduğu bir ara durum bırakmıyor.
    if (CastController.instance.isCasting) {
      // Önce GÖNDER, sonra ekranı güncelle.
      //
      // Tersi denenmişti: gönderim başarısız olduğunda telefon yeni videonun
      // başlığını gösterirken televizyon eskisini çalmaya devam ediyordu —
      // kullanıcı hangisinin doğru olduğunu anlayamıyordu.
      final sent = await CastController.instance.sendCurrent(
        videoId: videoId,
        title: details.title,
        artist: details.uploaderName,
        thumbnailUrl: details.thumbnailUrl,
      );
      if (_isStale(requestId)) return;
      if (!sent) {
        throw CastException(
          CastController.instance.lastError ??
              'Video televizyona gönderilemedi.',
        );
      }

      // Kuyruğun kurulacağı kaynak liste burada da GÜNCELLENMELİ; yoksa
      // "Sırada" bir önceki oynatmanın listesinden üretiliyordu.
      _prepareQueue(seed, details, exactQueue, index, videoId);
      _details = details;
      // Kalite ve ses/video seçimi televizyonun işi; telefon çözümleme bile
      // yapmıyor.
      _audioOnly = false;
      _qualityLabel = null;
      notifyListeners();

      await _library.recordWatch(seed);
      return;
    }

    // Açılış modu içeriğin türünden belirlenir; sonrası yalnızca kullanıcının.
    // Kullanıcı tercihi kapalıysa müzik de video modunda açılır.
    //
    // Televizyonda sesli mod hiç kullanılmıyor: ekran zaten karşıda ve
    // "ekranı kapatıp dinleme" diye bir senaryo yok — müzik videosu da
    // izlemek için açılıyor.
    final audioOnly = !forceVideo &&
        !TvMode.isTv.value &&
        _settings.musicAsAudio &&
        detectContentKind(details) == ContentKind.music;
    final streams = selectStreams(
      details,
      audioOnly: audioOnly,
      maxHeight: _settings.maxHeight,
    );
    if (streams == null) {
      throw const ExtractionException(
        'NO_STREAMS',
        'Bu video için oynatılabilir kaynak bulunamadı.',
      );
    }

    _prepareQueue(seed, details, exactQueue, index, videoId);

    _details = details;
    _audioOnly = audioOnly;
    _qualityLabel = streams.qualityLabel;
    notifyListeners();

    // Kuyruğu native tarafa ver ki ekran kapalıyken de ilerleyebilsin.
    await _playback.setQueue(
      _queue.map(_queueItem).toList(growable: false),
      _index,
    );
    if (_isStale(requestId)) return;
    await _playback.setAutoplay(_settings.autoplay);
    if (_isStale(requestId)) return;

    await _playback.play(
      audioUrl: streams.audioUrl,
      videoUrl: streams.videoUrl,
      title: details.title,
      artist: details.uploaderName,
      artworkUrl: details.thumbnailUrl,
      audioOnly: audioOnly,
      isLive: streams.isLive,
    );

    if (_isStale(requestId)) return;

    // "Kaldığın yerden devam": çağıran açıkça bir konum vermediyse yarım
    // bırakılan yer geçmişten okunuyor.
    //
    // Varsayılanın devam etmek olması bilinçli — kullanıcı videoyu nereden
    // açtığını (arama, geçmiş, ana sayfa) hatırlamak zorunda kalmasın diye.
    // Baştan başlatmak isteyen çağıran `startAt: Duration.zero` geçiyor.
    //
    // Sarma oynatma BAŞLADIKTAN sonra yapılıyor: oynatıcı kaynağı hazırlamadan
    // önce verilen konum yok sayılıyor.
    final resumeFrom = startAt ??
        Duration(milliseconds: _library.positionOf(videoId));
    if (resumeFrom > Duration.zero && !streams.isLive) {
      await _playback.seekTo(resumeFrom);
      if (_isStale(requestId)) return;
    }

    await _playback.setSpeed(_settings.speed);
    await _library.recordWatch(seed);

    // Bluetooth bağlanınca bu parça kaldığı yerden çalabilsin.
    await _playback.rememberLastPlayed(
      videoId: videoId,
      title: details.title,
      artist: details.uploaderName,
    );
  }

  /// "Sırada" listesini kurar. Yayın açıkken de kuruluyor: kullanıcı telefonda
  /// kuyruğu görüp içinden seçebilmeli.
  void _prepareQueue(
    VideoSummary seed,
    VideoDetails details,
    List<VideoSummary>? exactQueue,
    int? index,
    String videoId,
  ) {
    if (exactQueue != null) {
      // Çalma listesi gibi sırası kullanıcı tarafından belirlenmiş listeler
      // karıştırılmaz.
      _queueMode = QueueMode.listOrder;
      _queue = exactQueue;
      _index = index ?? exactQueue.indexWhere((v) => v.videoId == videoId);
    } else {
      // Kip BURADA sıfırlanıyor. Eskiden dokunulmuyordu ve bir çalma listesi
      // çalındıktan sonra aramadan açılan video da "liste sırası" kipinde
      // kalıyordu: kuyruk sessizce ilgili videoları içermiyor, arama
      // sonuçlarının sırasıyla gidiyordu.
      _queueMode = QueueMode.mixed;
      _queue = _buildQueue(seed, details);
      _index = 0;
    }
  }

  /// Kuyruğu kurar: çalan video başta, ardından benzer ama tekdüze olmayan
  /// içerik.
  ///
  /// Bir zamanlar ikinci bir seçenek daha vardı ("Aramaya göre"): kuyruk arama
  /// sonuçlarının sırasıyla kurulurdu. KALDIRILDI, çünkü asıl kullanımda
  /// istenmeyen sonucu veriyordu: bir şarkı arandığında sonuçlar da o şarkının
  /// varyasyonları (remiks, hızlandırılmış, kapak) oluyor ve kuyruk baştan
  /// sona aynı şarkıyı çalıyordu.
  List<VideoSummary> _buildQueue(VideoSummary seed, VideoDetails details) =>
      QueueBuilder.build(
        seed: seed,
        // Aday havuzu YALNIZCA videonun kendi önerileri.
        //
        // Kullanıcının o sırada gezindiği liste de havuza katılıyordu ve iki
        // kez ters tepti: arama sonuçları zaten aranan
        // şarkının varyasyonlarıyla dolu, ana sayfa akışı da son aramalardan
        // kurulduğu için aynı şeyi taşıyor. Sonuç, kuyruğun baştan sona aynı
        // şarkının remiks/hızlandırılmış sürümleri olması.
        //
        // İlgili videolar bu sorunu taşımıyor: YouTube'un otomatik
        // oynatmasının beslendiği kaynak da budur.
        candidates: details.relatedItems,
      );

  /// Çalan videonun gerçekten sunduğu çözünürlükler. Kalite menüsü bunu
  /// kullanır; sabit liste videoda olmayan seçenekler gösterirdi.
  List<int> get availableQualities {
    final details = _details;
    return details == null ? const [] : availableHeights(details);
  }

  /// Kaliteyi değiştirir ve çalan videoya HEMEN uygular (konum korunur).
  /// [maxHeight] null ise mevcut en yüksek kalite seçilir.
  Future<void> setQuality(int? maxHeight) async {
    await _settings.setMaxHeight(maxHeight);
    final details = _details;
    if (details == null || _audioOnly) {
      notifyListeners();
      return;
    }
    final streams =
        selectStreams(details, audioOnly: false, maxHeight: maxHeight);
    if (streams == null) return;
    _qualityLabel = streams.qualityLabel;
    notifyListeners();
    await _playback.replaceSources(
      videoUrl: streams.videoUrl,
      audioUrl: streams.audioUrl,
    );
  }

  Future<void> setRepeatMode(String mode) => _playback.setRepeatMode(mode);

  Future<void> setShuffle(bool enabled) => _playback.setShuffle(enabled);

  /// Native taraf kuyrukta ilerlediğinde (parça bitti → sıradaki) arayüzü
  /// gerçekte çalanla eşitler.
  Future<void> syncFromNative(String videoId, int nativeIndex) async {
    // Yayın açıkken telefonun kendi oynatıcısı duraklatılmış olsa da SON
    // yüklediği medyayı bildirmeye devam ediyor. Onu dinlemek ekranı
    // televizyonda çalanla değil, telefonda kalanla eşitlerdi: kullanıcı
    // televizyonda başka bir video izlerken telefonda eski başlığı görüyor,
    // düğmeler de başka bir şeyi yönetiyor gibi oluyordu.
    if (CastController.instance.isCasting) return;
    if (_details?.videoId == videoId) return;
    if (_syncFailedFor == videoId) return;

    // Bir hazırlık sürerken native'i DİNLEME.
    //
    // Bu metot durum akışından, saniyede birkaç kez çağrılıyor. Kullanıcı yeni
    // bir videoya dokunduğunda native hâlâ ÖNCEKİ parçayı bildiriyor: o
    // gecikmiş bilgi yeni seçimin üstüne yazıyor, seçilen video hiç açılmıyordu.
    // Hazırlık bitince zaten bir sonraki durum olayı eşitlemeyi yapar.
    if (_loading) return;

    final requestId = ++_requestId;
    _targetVideoId = videoId;
    _index = nativeIndex;

    // Kuyruk kendiliğinden ilerlediğinde de ESKİ videonun başlığı/kapağı
    // ekranda kalmasın: hazırlanıyor durumuna geç, kuyruktaki özeti göster.
    _loading = true;
    _pending = _queue.elementAtOrNull(nativeIndex);
    _details = null;
    notifyListeners();

    var failed = false;
    try {
      // Zaman aşımı ŞART: bu çağrının altında ağ var ve cevap gelmediğinde
      // `_loading` dakikalarca açık kalıyordu. O süre boyunca ekran
      // "Hazırlanıyor"da kilitli duruyor, üstelik native'den gelen bütün
      // durum bildirimleri (mod, kuyruk sırası, durdurma) yok sayılıyor —
      // kullanıcı bunu "uygulama dondu" olarak görüyor.
      final details = await _extraction
          .videoDetails(videoId)
          .timeout(_syncTimeout);
      if (_isStale(requestId)) return;
      _details = details;
      _syncFailedFor = null;
      _qualityLabel = null;
      notifyListeners();
      await _library.recordWatch(_summaryOf(details));
      // Kuyruk uzatma BEKLENMİYOR: arka planda çalışsın, arayüzün hazırlık
      // durumunu rehin almasın.
      unawaited(_extendQueueIfEnding(details, requestId));
    } catch (_) {
      // Meta veri alınamadı; oynatma yine de sürüyor. Ekranı boş bırakmamak
      // için kuyruktaki özet (başlık/kapak) yerinde kalır.
      failed = true;
      _syncFailedFor = videoId;
    } finally {
      if (!_isStale(requestId)) {
        _loading = false;
        if (!failed) _pending = null;
        notifyListeners();
      }
    }
  }

  /// Kullanıcının açık isteğiyle mod değiştirir; konum korunur.
  Future<void> toggleMode() async {
    final details = _details;
    if (details == null) return;
    final next = !_audioOnly;
    final streams = selectStreams(
      details,
      audioOnly: next,
      maxHeight: _settings.maxHeight,
    );
    if (streams == null) return;

    await _playback.setAudioOnly(
      next,
      videoUrl: streams.videoUrl,
      audioUrl: streams.audioUrl,
    );
    _audioOnly = next;
    _qualityLabel = streams.qualityLabel;
    notifyListeners();
  }

  /// Sıradakine geçer.
  ///
  /// Yayın açıkken kuyrukta ilerleme TELEVİZYONDA yaşıyor (kuyruğu oraya
  /// gönderdik); telefonun kendi oynatıcısına komut vermek sessiz bir
  /// oynatıcıyı ilerletmekten başka işe yaramazdı.
  Future<void> playNext() =>
      CastController.instance.isCasting
          ? CastController.instance.next()
          : _playback.next();

  Future<void> playPrevious() =>
      CastController.instance.isCasting
          ? CastController.instance.previous()
          : _playback.previous();

  /// Kuyruktan belirli bir videoya atlar.
  ///
  /// Yayın açıkken televizyonun kuyruğu telefonunkiyle aynı olmayabilir
  /// (televizyon kendi ilgili videolarını da katıyor); bu yüzden "kaçıncı
  /// sıradaki" değil, videonun KENDİSİ gönderiliyor.
  Future<void> playQueueIndex(int index) async {
    if (!CastController.instance.isCasting) {
      return _playback.playQueueIndex(index);
    }
    final target = _queue.elementAtOrNull(index)?.videoId;
    if (target == null) return;
    // Kuyruk KİPİ korunuyor: `exactQueue` vermek onu kalıcı olarak
    // "liste sırası"na çeviriyor ve yayın bittikten sonra kullanıcının
    // seçtiği filtre sessizce değişmiş oluyordu.
    final mode = _queueMode;
    await play(target, exactQueue: _queue, index: index);
    _queueMode = mode;
  }

  /// Oynatmayı sürdürür; yayın açıkken komut televizyona gider.
  ///
  /// Telefonun kendi oynatıcısını başlatmak, televizyon da çalarken aynı sesin
  /// iki yerden gelmesine yol açıyordu.
  Future<void> resume() async {
    if (CastController.instance.isCasting) {
      return CastController.instance.resume();
    }
    await _playback.resume();
  }

  Future<void> pause() => CastController.instance.isCasting
      ? CastController.instance.pause()
      : _playback.pause();

  /// Bulunulan yerden [offset] kadar sarar.
  /// Native'in bildirdiği ses/video modunu alır.
  ///
  /// Oynatmanın sahibi native taraf: kuyrukta sıradakine o geçiyor ve modu o
  /// taşıyor. Dart'ın kendi bayrağı bu yüzden onunla eşitleniyor; eşitlenmezse
  /// arayüz oynatmanın gerçekte hangi modda olduğunu bilmiyor.
  ///
  /// Hazırlık sürerken DİNLENMİYOR: yeni video için mod zaten burada
  /// belirlendi, native hâlâ öncekini bildiriyor olabilir ve o gecikmiş bilgi
  /// yeni kararın üstüne yazardı.
  void updateAudioOnly(bool value) {
    if (_loading || _audioOnly == value) return;
    _audioOnly = value;
    notifyListeners();
  }

  /// Native'in bildirdiği çalma sırasını alır.
  ///
  /// Durum akışından besleniyor; karıştırma açılıp kapandığında ya da kuyruk
  /// değiştiğinde sıra da değişiyor.
  void updatePlayOrder(List<int> order) {
    if (_playOrder.length == order.length) {
      var same = true;
      for (var i = 0; i < order.length; i++) {
        if (_playOrder[i] != order[i]) {
          same = false;
          break;
        }
      }
      // Akış saniyede birkaç kez geliyor; değişmemiş sırada arayüzü yeniden
      // çizmenin karşılığı yok.
      if (same) return;
    }
    _playOrder = List.unmodifiable(order);
    notifyListeners();
  }

  /// Kuyruğun sonuna yaklaşıldıysa öneriyle uzatır.
  ///
  /// Kuyruk bitince oynatma DURUYORDU; müzik dinlerken bu, birkaç şarkı sonra
  /// gelen sessizlik demekti. Artık sona yaklaşınca çalan videonun ilgili
  /// videolarından kuyruk uzuyor ve dinleme kesintisiz sürüyor.
  ///
  /// Yalnızca [QueueMode.mixed] kipinde: kullanıcı bir çalma listesi açtıysa
  /// listenin sonu GERÇEKTEN sondur, arkasına öneri eklemek onun seçimini
  /// bozardı.
  ///
  /// Otomatik oynatma kapalıysa hiç uzatılmıyor — kullanıcı zaten "bittiğinde
  /// dursun" demiş.
  Future<void> _extendQueueIfEnding(VideoDetails details, int requestId) async {
    if (!_settings.autoplay) return;
    if (_queueMode != QueueMode.mixed) return;
    if (_queue.length >= QueueBuilder.maxTotalQueueLength) return;
    if (_index < _queue.length - _extendWhenRemaining) return;

    final addition = QueueBuilder.extend(
      current: _summaryOf(details),
      existing: _queue,
      candidates: details.relatedItems,
    );
    if (addition.isEmpty || _isStale(requestId)) return;

    _queue = [..._queue, ...addition];
    notifyListeners();
    // Native kuyruğun sahibi; ekran kapalıyken sıradakine o geçiyor, bu yüzden
    // uzayan listeyi ONA da bildirmek şart. İndeks korunuyor: `setQueue`
    // çalanı kesmiyor (kip değiştirmede de aynı yol kullanılıyor).
    await _playback.setQueue(
      _queue.map(_queueItem).toList(growable: false),
      _index,
    );
  }

  /// Sıradaki parçanın meta verisi için beklenecek en uzun süre.
  ///
  /// Aşılırsa oynatma sürmeye devam ediyor; yalnızca başlık/kapak kuyruktaki
  /// özetten gösteriliyor. Süresiz beklemek arayüzü kilitliyordu.
  static const _syncTimeout = Duration(seconds: 15);

  /// Kuyruğun sonuna bu kadar video kaldığında uzatma tetikleniyor.
  ///
  /// Sıfır beklemek geç kalırdı: uzatma bir çıkarma isteği gerektiriyor ve o
  /// sürede video bitip oynatma durabilirdi.
  static const _extendWhenRemaining = 3;

  Future<void> seekBy(Duration offset, Duration current) {
    final target = current + offset;
    final clamped = target < Duration.zero ? Duration.zero : target;
    return CastController.instance.isCasting
        ? CastController.instance.seekTo(clamped)
        : _playback.seekTo(clamped);
  }

  Future<void> setAutoplay(bool value) async {
    await _settings.setAutoplay(value);
    await _playback.setAutoplay(value);
    notifyListeners();
  }

  /// Oynatma uygulama DIŞINDAN bitirildiğinde (bildirimdeki kapat düğmesi)
  /// arayüzü temizler. Native'e komut göndermez — orada zaten durdu.
  void handleStoppedExternally() {
    // Yayın açıkken telefonun oynatıcısı zaten susturuldu; onun "durdum"
    // demesi televizyonda çalanı ekrandan silmemeli.
    if (CastController.instance.isCasting) return;
    // Yeni bir medya hazırlanıyorsa bu, henüz medya yüklenmemiş olmasından
    // kaynaklanan geçici bir durumdur; temizlemek hazırlığı bozardı.
    if (_loading) return;
    if (_details == null && _queue.isEmpty) return;

    _targetVideoId = null;
    _details = null;
    _pending = null;
    _qualityLabel = null;
    _queue = const [];
    _index = -1;
    notifyListeners();
  }

  Future<void> stop() async {
    await _playback.stop();
    _targetVideoId = null;
    _details = null;
    _qualityLabel = null;
    _queue = const [];
    _index = -1;
    notifyListeners();
  }

  VideoSummary _summaryOf(VideoDetails d) => VideoSummary(
        videoId: d.videoId,
        title: d.title,
        url: 'https://www.youtube.com/watch?v=${d.videoId}',
        uploaderName: d.uploaderName,
        durationSeconds: d.durationSeconds,
        viewCount: d.viewCount,
        textualUploadDate: null,
        thumbnailUrl: d.thumbnailUrl,
      );

  Map<String, Object?> _queueItem(VideoSummary v) => {
        'videoId': v.videoId,
        'title': v.title,
        'uploaderName': v.uploaderName,
        'thumbnailUrl': v.thumbnailUrl,
      };
}

/// "Sırada" listesinin nasıl kurulacağı.
enum QueueMode {
  /// Girilen listenin (arama sonuçları / akış) sırası korunur.
  listOrder,

  /// İlgili videolarla genişletilip aynı sanatçı yığılmayacak şekilde
  /// karıştırılır.
  mixed,
}
