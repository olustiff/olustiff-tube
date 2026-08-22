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
    final audioOnly = detectContentKind(details) == ContentKind.music;
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
      _queue = exactQueue;
      _index = index ?? exactQueue.indexWhere((v) => v.videoId == videoId);
    } else {
      _queue = QueueBuilder.build(
        seed: seed,
        candidates: [...context, ...details.relatedItems],
      );
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

    await _playback.setAudioOnly(next);
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
