import 'package:flutter/services.dart';

import 'models.dart';

/// Native Kotlin tarafındaki [MainActivity]'de kaydedilen `akis/extractor`
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
      : _channel = channel ?? const MethodChannel('akis/extractor');

  final MethodChannel _channel;

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      throw ExtractionException(
        e.code,
        e.message ?? 'Bilinmeyen bir çıkarma hatası oluştu.',
      );
    }
  }

  Future<List<VideoSummary>> search(String query) async {
    final raw = await _invoke<List<Object?>>('search', {'query': query});
    return raw
        .map((e) => VideoSummary.fromMap(e as Map<Object?, Object?>))
        .toList(growable: false);
  }

  Future<List<VideoSummary>> trending() async {
    final raw = await _invoke<List<Object?>>('trending');
    return raw
        .map((e) => VideoSummary.fromMap(e as Map<Object?, Object?>))
        .toList(growable: false);
  }

  Future<VideoDetails> videoDetails(String videoId) async {
    final raw =
        await _invoke<Map<Object?, Object?>>('videoDetails', {'videoId': videoId});
    return VideoDetails.fromMap(raw);
  }
}
