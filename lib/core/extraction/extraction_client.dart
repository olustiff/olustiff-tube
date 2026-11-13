import 'package:flutter/services.dart';

import 'models.dart';
import '../i18n/lang.dart';

/// Native Kotlin tarafındaki [MainActivity]'de kaydedilen `olustiff/extractor`
/// MethodChannel'ının Dart yüzü. Tüm çağrılar native tarafta IO thread'inde
/// koşuyor (bkz. ExtractionService.kt) — burada asla UI donmaz.
class ExtractionException implements Exception {
  final String code;
  final String message;

  const ExtractionException(this.code, this.message);

  @override
  String toString() => 'ExtractionException($code): $message';
}

class ExtractionClient {
  ExtractionClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('olustiff/extractor');

  final MethodChannel _channel;

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      throw ExtractionException(
        e.code,
        e.message ??
            tr('Bilinmeyen bir çıkarma hatası oluştu.',
                'An unknown extraction error occurred.'),
      );
    }
  }

  /// Sayfalanabilir liste türleri — [loadMore] bunlarla çağrılır.
  static const kindSearch = 'search';
  static const kindTrending = 'trending';
  static const kindPlaylist = 'playlist';
  static const kindChannel = 'channel';
  static const kindSearchPlaylists = 'search_playlists';
  static const kindSearchChannels = 'search_channels';

  /// [keepSession] false ise sonuç [loadMore] için saklanmaz; arka plan
  /// aramaları (ana sayfa akışı) arama ekranının devamını bozmasın diye.
  Future<PagedVideos> search(String query, {bool keepSession = true}) async {
    final raw = await _invoke<Map<Object?, Object?>>(
      'search',
      {'query': query, 'keepSession': keepSession},
    );
    return PagedVideos.fromMap(raw);
  }

  /// Arama kutusuna yazarken YouTube'un önerdiği tamamlamalar.
  ///
  /// Yazdıkça çağrıldığı için çağıran taraf istekleri geciktirmeli ve
  /// eskiyeni atmalı (bkz. [SuggestionLoader]).
  Future<List<String>> suggestions(String query) async {
    final raw =
        await _invoke<List<Object?>>('suggestions', {'query': query});
    return raw.whereType<String>().toList();
  }

  Future<PagedVideos> trending() async {
    final raw = await _invoke<Map<Object?, Object?>>('trending');
    return PagedVideos.fromMap(raw);
  }

  /// Açık listenin bir sonraki sayfasını getirir. Son sayfadan sonra boş
  /// sonuç döner, bu yüzden sonsuz kaydırma güvenle durur.
  Future<PagedVideos> loadMore(String kind) async {
    final raw =
        await _invoke<Map<Object?, Object?>>('loadMore', {'kind': kind});
    return PagedVideos.fromMap(raw);
  }

  /// Yalnızca çalma listelerini ([kindSearchPlaylists]) ya da yalnızca
  /// kanalları ([kindSearchChannels]) arar.
  ///
  /// Genel arama kanal döndürmüyor ve listelerden de yalnızca bir ikisini
  /// veriyor; filtreli arama o türe ayrılmış sonuç sayfasını getiriyor.
  Future<PagedVideos> searchFiltered(String query, String kind) async {
    final raw = await _invoke<Map<Object?, Object?>>(
      'searchFiltered',
      {'query': query, 'kind': kind},
    );
    return PagedVideos.fromMap(raw);
  }

  /// Bir kanalın videoları (ilk sayfa); devamı [loadMore] ile.
  Future<ChannelDetails> channel(String url) async {
    final raw = await _invoke<Map<Object?, Object?>>('channel', {'url': url});
    return ChannelDetails.fromMap(raw);
  }

  Future<PlaylistDetails> playlist(String url) async {
    final raw = await _invoke<Map<Object?, Object?>>('playlist', {'url': url});
    return PlaylistDetails.fromMap(raw);
  }

  Future<VideoDetails> videoDetails(String videoId) async {
    final raw =
        await _invoke<Map<Object?, Object?>>('videoDetails', {'videoId': videoId});
    return VideoDetails.fromMap(raw);
  }
}
