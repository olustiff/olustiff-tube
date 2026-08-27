import 'dart:async';

import 'package:flutter/foundation.dart';

import '../playback/playback_client.dart';
import 'cast_client.dart';
import 'cast_discovery.dart';
import 'cast_protocol.dart';

/// "Şu an televizyona mı gönderiyoruz" durumunun tek sahibi.
///
/// Telefon tarafında yaşar. Yayın açıkken telefondaki oynatma DURDURULUR
/// (aynı sesin iki yerden gelmesi kullanıcıya arıza gibi görünüyor) ve
/// ekrandaki kontroller televizyona komut göndermeye başlar.
class CastController extends ChangeNotifier {
  CastController({
    CastDiscovery discovery = const CastDiscovery(),
    CastClient Function(CastDevice)? clientFactory,
  })  : _discovery = discovery,
        _clientFactory = clientFactory ?? CastClient.new;

  static final CastController instance = CastController();

  final CastDiscovery _discovery;
  final CastClient Function(CastDevice) _clientFactory;

  CastClient? _client;
  Timer? _poll;

  CastDevice? _device;

  /// Yayının gittiği televizyon; yayın kapalıysa null.
  CastDevice? get device => _device;
  bool get isCasting => _device != null;

  CastRemoteState? _remoteState;

  /// Televizyonda çalanın son bilinen hâli. Yoklamayla güncellenir.
  CastRemoteState? get remoteState => _remoteState;

  bool _searching = false;
  bool get isSearching => _searching;

  /// Kullanıcıya gösterilecek son hata. Okunduktan sonra
  /// [clearError] ile temizlenir; aynı hata tekrar tekrar gösterilmez.
  String? _lastError;
  String? get lastError => _lastError;

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// Ağdaki televizyonları arar.
  Future<List<CastDevice>> search() async {
    _searching = true;
    notifyListeners();
    try {
      return await _discovery.discover();
    } finally {
      _searching = false;
      notifyListeners();
    }
  }

  /// Videoyu televizyona gönderir ve telefondaki oynatmayı durdurur.
  ///
  /// Sıralama önemli: önce televizyonun isteği KABUL ettiğini görüyoruz,
  /// sonra telefonu susturuyoruz. Tersi olsaydı televizyona ulaşılamadığında
  /// kullanıcı hem susmuş bir telefonla hem de boş bir televizyonla kalırdı.
  Future<bool> castTo(
    CastDevice target, {
    required String videoId,
    required String title,
    String? artist,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) async {
    final client = _clientFactory(target);
    try {
      await client.play(
        videoId: videoId,
        title: title,
        artist: artist,
        thumbnailUrl: thumbnailUrl,
        position: position,
      );
    } on CastException catch (e) {
      client.close();
      _lastError = e.message;
      notifyListeners();
      return false;
    }

    _client?.close();
    _client = client;
    _device = target;
    _remoteState = CastRemoteState(
      videoId: videoId,
      title: title,
      position: position,
      isPlaying: true,
    );
    _lastError = null;
    notifyListeners();

    await PlaybackClient.shared.pause();
    _startPolling();
    return true;
  }

  /// Televizyondaki videoyu değiştirir (yayın açıkken yeni bir videoya
  /// dokunulduğunda). Bağlantı korunur.
  Future<bool> sendCurrent({
    required String videoId,
    required String title,
    String? artist,
    String? thumbnailUrl,
    Duration position = Duration.zero,
  }) async {
    final target = _device;
    if (target == null) return false;
    return castTo(
      target,
      videoId: videoId,
      title: title,
      artist: artist,
      thumbnailUrl: thumbnailUrl,
      position: position,
    );
  }

  Future<void> resume() => _send(CastCommand.resume);

  Future<void> pause() => _send(CastCommand.pause);

  Future<void> next() => _send(CastCommand.next);

  Future<void> previous() => _send(CastCommand.previous);

  Future<void> seekTo(Duration position) =>
      _send(CastCommand.seek, position: position);

  /// Televizyonda çalanı durdurup yayını kapatır.
  Future<void> stopRemote() async {
    await _send(CastCommand.stop);
    await disconnect();
  }

  /// Yayını kapatır; televizyondaki oynatmaya DOKUNMAZ.
  ///
  /// Kullanıcı çoğu zaman "telefonu bırakıp televizyonda izlemeye devam"
  /// istiyor; bağlantıyı kesmenin televizyonu da susturması sürpriz olurdu.
  Future<void> disconnect() async {
    _poll?.cancel();
    _poll = null;
    _client?.close();
    _client = null;
    _device = null;
    _remoteState = null;
    notifyListeners();
  }

  Future<void> _send(String action, {Duration? position}) async {
    final client = _client;
    if (client == null) return;
    try {
      await client.command(action, position: position);
      // Kullanıcı düğmeye bastığında arayüz beklemeden tepki vermeli;
      // yoklama saniyeler sonra geliyor.
      _applyOptimistic(action, position);
    } on CastException catch (e) {
      _lastError = e.message;
      notifyListeners();
    }
  }

  /// Komutun beklenen sonucunu yerel duruma hemen yansıtır.
  void _applyOptimistic(String action, Duration? position) {
    final state = _remoteState;
    if (state == null) return;
    _remoteState = switch (action) {
      CastCommand.resume => CastRemoteState(
          videoId: state.videoId,
          title: state.title,
          position: state.position,
          duration: state.duration,
          isPlaying: true,
        ),
      CastCommand.pause => CastRemoteState(
          videoId: state.videoId,
          title: state.title,
          position: state.position,
          duration: state.duration,
          isPlaying: false,
        ),
      CastCommand.seek => CastRemoteState(
          videoId: state.videoId,
          title: state.title,
          position: position ?? state.position,
          duration: state.duration,
          isPlaying: state.isPlaying,
        ),
      _ => state,
    };
    notifyListeners();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final client = _client;
      if (client == null) return;
      final state = await client.remoteState();
      // null = ulaşılamadı. Bağlantıyı burada KESMİYORUZ: tek bir paket
      // kaybı yüzünden kullanıcının kumandasını elinden almak yanlış olur.
      if (state == null) return;
      _remoteState = state;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _client?.close();
    super.dispose();
  }
}
