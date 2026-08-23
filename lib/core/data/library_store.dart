import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../extraction/models.dart';

/// Kullanıcının cihazında kalıcı olan her şey: arama geçmişi, izleme geçmişi
/// ve uygulama içi çalma listeleri.
///
/// Hepsi tek yerde çünkü ana sayfa önerileri bu verilerin birleşiminden
/// üretiliyor.
class LibraryStore extends ChangeNotifier {
  LibraryStore._();

  static final LibraryStore instance = LibraryStore._();

  static const _kSearches = 'search_history';
  static const _kWatched = 'watch_history';
  static const _kPlaylists = 'playlists';
  static const _kPlayCounts = 'play_counts';

  static const _maxSearches = 40;
  static const _maxWatched = 200;

  SharedPreferences? _prefs;

  List<String> _searches = [];
  List<VideoSummary> _watched = [];

  /// videoId → kaç kez oynatıldı. "En çok dinlediklerin" bundan üretilir.
  Map<String, int> _playCounts = {};
  Map<String, List<VideoSummary>> _playlists = {};

  List<String> get searches => List.unmodifiable(_searches);
  List<VideoSummary> get watched => List.unmodifiable(_watched);

  int playCountOf(String videoId) => _playCounts[videoId] ?? 0;

  /// Geçmişte en çok tekrar edilen içerikler (çoktan aza).
  ///
  /// Tek kez açılanlar sayılmaz; liste "en çok dinlediklerin" anlamını
  /// korusun diye en az iki kez oynatılmış olanlar gösterilir.
  List<VideoSummary> get mostPlayed {
    final repeated = _watched
        .where((v) => v.videoId != null && playCountOf(v.videoId!) > 1)
        .toList();
    repeated.sort(
      (a, b) => playCountOf(b.videoId!).compareTo(playCountOf(a.videoId!)),
    );
    return List.unmodifiable(repeated);
  }

  /// En çok dinlenen kanallar (çoktan aza). Ana sayfa önerileri bunları
  /// tohum olarak kullanır: sık dinlenen sanatçı daha isabetli öneri verir.
  List<String> get topChannels {
    final counts = <String, int>{};
    for (final video in _watched) {
      final channel = video.uploaderName;
      final id = video.videoId;
      if (channel == null || channel.isEmpty || id == null) continue;
      counts[channel] = (counts[channel] ?? 0) + playCountOf(id);
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => e.key).toList();
  }

  Map<String, List<VideoSummary>> get playlists => Map.unmodifiable(_playlists);

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();

    _searches = prefs.getStringList(_kSearches) ?? [];
    _watched = _decodeVideos(prefs.getString(_kWatched));

    final rawCounts = prefs.getString(_kPlayCounts);
    if (rawCounts != null) {
      _playCounts = (jsonDecode(rawCounts) as Map<String, dynamic>)
          .map((key, value) => MapEntry(key, (value as num).toInt()));
    }

    final rawPlaylists = prefs.getString(_kPlaylists);
    if (rawPlaylists != null) {
      final decoded = jsonDecode(rawPlaylists) as Map<String, dynamic>;
      _playlists = {
        for (final entry in decoded.entries)
          entry.key: (entry.value as List<dynamic>)
              .map((e) => _videoFromJson(e as Map<String, dynamic>))
              .toList(),
      };
    }
    notifyListeners();
  }

  // --- Arama geçmişi ---

  Future<void> recordSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    // En son arama başa gelsin, tekrar edenler çoğalmasın.
    _searches.removeWhere((s) => s.toLowerCase() == trimmed.toLowerCase());
    _searches.insert(0, trimmed);
    if (_searches.length > _maxSearches) {
      _searches = _searches.sublist(0, _maxSearches);
    }
    await _prefs?.setStringList(_kSearches, _searches);
    notifyListeners();
  }

  Future<void> removeSearch(String query) async {
    _searches.remove(query);
    await _prefs?.setStringList(_kSearches, _searches);
    notifyListeners();
  }

  Future<void> clearSearches() async {
    _searches = [];
    await _prefs?.setStringList(_kSearches, _searches);
    notifyListeners();
  }

  // --- İzleme geçmişi ---

  Future<void> recordWatch(VideoSummary video) async {
    final videoId = video.videoId;
    if (videoId == null) return;
    _watched.removeWhere((v) => v.videoId == videoId);
    _watched.insert(0, video);
    if (_watched.length > _maxWatched) {
      _watched = _watched.sublist(0, _maxWatched);
    }
    _playCounts[videoId] = (_playCounts[videoId] ?? 0) + 1;

    await _prefs?.setString(_kWatched, _encodeVideos(_watched));
    await _prefs?.setString(_kPlayCounts, jsonEncode(_playCounts));
    notifyListeners();
  }

  Future<void> clearWatched() async {
    _watched = [];
    _playCounts = {};
    await _prefs?.setString(_kWatched, _encodeVideos(_watched));
    await _prefs?.setString(_kPlayCounts, jsonEncode(_playCounts));
    notifyListeners();
  }

  // --- Çalma listeleri ---

  Future<void> createPlaylist(String name) async {
    if (name.trim().isEmpty || _playlists.containsKey(name)) return;
    _playlists[name] = [];
    await _savePlaylists();
  }

  Future<void> deletePlaylist(String name) async {
    _playlists.remove(name);
    await _savePlaylists();
  }

  Future<void> addToPlaylist(String name, VideoSummary video) async {
    final list = _playlists[name];
    if (list == null || video.videoId == null) return;
    if (list.any((v) => v.videoId == video.videoId)) return;
    list.add(video);
    await _savePlaylists();
  }

  Future<void> removeFromPlaylist(String name, String videoId) async {
    _playlists[name]?.removeWhere((v) => v.videoId == videoId);
    await _savePlaylists();
  }

  Future<void> _savePlaylists() async {
    final encoded = jsonEncode({
      for (final entry in _playlists.entries)
        entry.key: entry.value.map(_videoToJson).toList(),
    });
    await _prefs?.setString(_kPlaylists, encoded);
    notifyListeners();
  }

  // --- Serileştirme ---

  String _encodeVideos(List<VideoSummary> videos) =>
      jsonEncode(videos.map(_videoToJson).toList());

  List<VideoSummary> _decodeVideos(String? raw) {
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => _videoFromJson(e as Map<String, dynamic>))
        .toList();
  }

  Map<String, Object?> _videoToJson(VideoSummary v) => {
        'videoId': v.videoId,
        'title': v.title,
        'url': v.url,
        'uploaderName': v.uploaderName,
        'durationSeconds': v.durationSeconds,
        'viewCount': v.viewCount,
        'textualUploadDate': v.textualUploadDate,
        'thumbnailUrl': v.thumbnailUrl,
      };

  VideoSummary _videoFromJson(Map<String, dynamic> json) => VideoSummary(
        videoId: json['videoId'] as String?,
        title: json['title'] as String? ?? '',
        url: json['url'] as String?,
        uploaderName: json['uploaderName'] as String?,
        durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
        viewCount: (json['viewCount'] as num?)?.toInt() ?? 0,
        textualUploadDate: json['textualUploadDate'] as String?,
        thumbnailUrl: json['thumbnailUrl'] as String?,
      );
}
