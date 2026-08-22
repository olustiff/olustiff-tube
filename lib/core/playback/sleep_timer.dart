import 'dart:async';

import 'package:flutter/foundation.dart';

import 'playback_client.dart';

/// Uyku zamanlayıcısı: belirlenen süre sonunda oynatmayı duraklatır.
///
/// Duraklatır, durdurmaz — kullanıcı uyanınca kaldığı yerden devam edebilsin.
class SleepTimer extends ChangeNotifier {
  SleepTimer._();

  static final SleepTimer instance = SleepTimer._();

  static const options = <Duration>[
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
    Duration(hours: 2),
  ];

  Timer? _timer;
  DateTime? _endsAt;

  bool get isActive => _endsAt != null;

  /// Kalan süre; zamanlayıcı yoksa null.
  Duration? get remaining {
    final endsAt = _endsAt;
    if (endsAt == null) return null;
    final left = endsAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void start(Duration duration) {
    cancel();
    _endsAt = DateTime.now().add(duration);
    _timer = Timer(duration, () {
      PlaybackClient.shared.pause();
      _endsAt = null;
      _timer = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
