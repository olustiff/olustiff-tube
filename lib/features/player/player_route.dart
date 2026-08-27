import 'package:flutter/material.dart';

import 'player_screen.dart';

/// Oynatma ekranı şu an açık mı.
///
/// Televizyona telefondan bir video gönderildiğinde ekranı AÇMAK gerekiyor;
/// ama zaten açıksa ikinci bir kopya açmak geri tuşunda üst üste yığılmış
/// oynatıcılar bırakırdı.
bool get isPlayerOpen => _openPlayers > 0;

int _openPlayers = 0;

/// Oynatma ekranını açar.
///
/// YouTube'daki gibi: ekran aşağı kaydırılarak kapatılabilir ve kapandığında
/// oynatma durmaz — alttaki mini oynatıcıdan devam eder.
Future<void> openPlayer(BuildContext context, String videoId) {
  return Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      // Küçülme hissi için alttan yukarı açılıyor.
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) =>
          _DismissiblePlayer(videoId: videoId),
      transitionsBuilder: (context, animation, secondary, child) {
        return SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          )),
          child: child,
        );
      },
    ),
  );
}

/// Aşağı sürüklenerek kapatılabilen oynatma ekranı.
class _DismissiblePlayer extends StatefulWidget {
  const _DismissiblePlayer({required this.videoId});

  final String videoId;

  @override
  State<_DismissiblePlayer> createState() => _DismissiblePlayerState();
}

class _DismissiblePlayerState extends State<_DismissiblePlayer> {
  /// Ekranın ne kadar aşağı çekildiği.
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _openPlayers++;
  }

  @override
  void dispose() {
    _openPlayers--;
    super.dispose();
  }

  /// Bu mesafeyi geçen bir sürükleme "kapat" sayılır.
  static const _dismissThreshold = 140.0;

  /// Bu hızın üstünde hızlı bir savurma da kapatır — kullanıcı uzun
  /// sürüklemek zorunda kalmasın.
  static const _dismissVelocity = 700.0;

  void _onDragUpdate(DragUpdateDetails details) {
    // Yalnızca aşağı yön; yukarı çekmek ekranı taşımasın.
    final next = _offset + details.delta.dy;
    setState(() => _offset = next < 0 ? 0 : next);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_offset > _dismissThreshold || velocity > _dismissVelocity) {
      // Oynatma native tarafta sürdüğü için ekranı kapatmak yeterli;
      // mini oynatıcı çalanı göstermeye devam eder.
      Navigator.of(context).pop();
      return;
    }
    setState(() => _offset = 0);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    // Aşağı indikçe biraz saydamlaşsın: küçülüyor hissi versin.
    final progress = (_offset / height).clamp(0.0, 1.0);

    return Transform.translate(
      offset: Offset(0, _offset),
      child: Opacity(
        opacity: 1 - progress * 0.4,
        // Sürükleme ekranın HER YERİNDEN başlar. Alttaki liste kendi
        // kaydırmasını yaptığı için jest yarışını o kazanır; video ve
        // kontrol alanında ise sürükleme buraya düşer.
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: PlayerScreen(videoId: widget.videoId),
        ),
      ),
    );
  }
}
