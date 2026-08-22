import 'package:flutter/foundation.dart';

import '../data/library_store.dart';
import '../data/settings_store.dart';
import '../extraction/extraction_client.dart';
import '../extraction/models.dart';
import 'content_kind.dart';
import 'playback_client.dart';
import 'queue_builder.dart';
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

  /// Kuyruğun kurulduğu ham liste (arama sonuçları / akış). Filtre
  /// değiştiğinde kuyruk bundan yeniden üretilir.
  List<VideoSummary> _sourceList = const [];
  QueueMode _queueMode = QueueMode.mixed;

  QueueMode get queueMode => _queueMode;

  VideoDetails? get details => _details;
  bool get audioOnly => _audioOnly;
  String? get qualityLabel => _qualityLabel;
  bool get hasMedia => _details != null;
  List<VideoSummary> get queue => List.unmodifiable(_queue);
  int get queueIndex => _index;

  bool isCurrent(String videoId) => _details?.videoId == videoId;

  VideoSummary? get upNext {
    final next = _index + 1;
    return next >= 0 && next < _queue.length ? _queue[next] : null;
  }

  /// Bir videoyu çalar.
  ///
  /// [context] videonun içinden seçildiği liste (arama sonuçları, geçmiş,
  /// çalma listesi). Kuyruk buradan ve videonun ilgili videolarından
  /// karıştırılarak kurulur — böylece hep aynı sanatçı tekrarlanmaz.
  Future<void> play(
    String videoId, {
    List<VideoSummary> context = const [],
    List<VideoSummary>? exactQueue,
    int? index,
  }) async {
    final details = await _extraction.videoDetails(videoId);

    // Açılış modu içeriğin türünden belirlenir; sonrası yalnızca kullanıcının.
    // Kullanıcı tercihi kapalıysa müzik de video modunda açılır.
    final audioOnly = _settings.musicAsAudio &&
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

    final seed = _summaryOf(details);

    if (exactQueue != null) {
      // Çalma listesi gibi sırası kullanıcı tarafından belirlenmiş listeler
      // karıştırılmaz.
      _sourceList = exactQueue;
      _queueMode = QueueMode.listOrder;
      _queue = exactQueue;
      _index = index ?? exactQueue.indexWhere((v) => v.videoId == videoId);
    } else {
      _sourceList = context;
      _queue = _buildQueue(seed, details);
      _index = 0;
    }

    _details = details;
    _audioOnly = audioOnly;
    _qualityLabel = streams.qualityLabel;
    notifyListeners();

    // Kuyruğu native tarafa ver ki ekran kapalıyken de ilerleyebilsin.
    await _playback.setQueue(
      _queue.map(_queueItem).toList(growable: false),
      _index,
    );
    await _playback.setAutoplay(_settings.autoplay);

    await _playback.play(
      audioUrl: streams.audioUrl,
      videoUrl: streams.videoUrl,
      title: details.title,
      artist: details.uploaderName,
      artworkUrl: details.thumbnailUrl,
      audioOnly: audioOnly,
      isLive: streams.isLive,
    );

    await _playback.setSpeed(_settings.speed);
    await _library.recordWatch(seed);
  }

  List<VideoSummary> _buildQueue(VideoSummary seed, VideoDetails details) {
    if (_queueMode == QueueMode.listOrder) {
      // "Aramaya göre": kaynak listenin sırası korunur, çalan video başa alınır.
      final rest = _sourceList
          .where((v) => v.videoId != null && v.videoId != seed.videoId)
          .toList();
      return [seed, ...rest];
    }
    return QueueBuilder.build(
      seed: seed,
      candidates: [..._sourceList, ...details.relatedItems],
    );
  }

  /// Kuyruk filtresini değiştirir: kaynak listenin sırası mı, karışık mı.
  /// Çalan parça kesilmez, yalnızca sırası yeniden kurulur.
  Future<void> setQueueMode(QueueMode mode) async {
    if (_queueMode == mode) return;
    _queueMode = mode;
    final details = _details;
    if (details == null) {
      notifyListeners();
      return;
    }
    _queue = _buildQueue(_summaryOf(details), details);
    _index = 0;
    notifyListeners();
    await _playback.setQueue(
      _queue.map(_queueItem).toList(growable: false),
      _index,
    );
  }

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
    if (_details?.videoId == videoId) return;
    _index = nativeIndex;
    try {
      final details = await _extraction.videoDetails(videoId);
      _details = details;
      _qualityLabel = null;
      notifyListeners();
      await _library.recordWatch(_summaryOf(details));
    } catch (_) {
      // Meta veri alınamazsa oynatma yine de sürüyor; arayüz eski başlıkta
      // kalmaktansa kuyruktaki özeti gösterir.
      final fallback = _queue.elementAtOrNull(nativeIndex);
      if (fallback != null) notifyListeners();
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

  Future<void> playNext() => _playback.next();

  Future<void> playPrevious() => _playback.previous();

  Future<void> playQueueIndex(int index) => _playback.playQueueIndex(index);

  Future<void> setAutoplay(bool value) async {
    await _settings.setAutoplay(value);
    await _playback.setAutoplay(value);
    notifyListeners();
  }

  Future<void> stop() async {
    await _playback.stop();
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
