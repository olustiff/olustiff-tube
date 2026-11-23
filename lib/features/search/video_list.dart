import 'dart:async';

import 'package:flutter/material.dart';
import 'package:olustiff/core/ui/thumb_image.dart';

import '../../core/extraction/models.dart';
import '../../core/i18n/lang.dart';
import '../../core/ui/tv_mode.dart';

/// Sonsuz kaydırmalı video listesi.
///
/// YouTube tek istekte ~20 sonuç verdiği için liste sonuna yaklaşıldığında
/// [onLoadMore] tetiklenir; böylece arama sonuçları "kısa" kalmaz.
class VideoList extends StatefulWidget {
  const VideoList({
    super.key,
    required this.videos,
    required this.loading,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
    this.error,
    this.onRetry,
    this.emptyMessage,
  });

  final List<VideoSummary> videos;
  final bool loading;
  final bool hasMore;
  final Object? error;
  final VoidCallback? onRetry;
  /// Boşsa 'Sonuç bulunamadı.' (dil çizim anında seçilsin diye burada).
  final String? emptyMessage;
  final VoidCallback onLoadMore;
  final void Function(int index) onTap;

  @override
  State<VideoList> createState() => _VideoListState();
}

class _VideoListState extends State<VideoList> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Kullanıcı listenin sonuna varmadan yüklemeye başla ki kaydırma akıcı
    // kalsın ve bekleme hissedilmesin.
    if (position.pixels >= position.maxScrollExtent - 600) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.error != null && widget.videos.isEmpty) {
      return _ErrorView(error: widget.error, onRetry: widget.onRetry);
    }
    if (widget.videos.isEmpty) {
      return Center(
        child: widget.loading
            ? const CircularProgressIndicator()
            : Text(widget.emptyMessage ??
                tr('Sonuç bulunamadı.', 'No results found.')),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      // Son satır, daha fazlası varken yükleme göstergesi olur.
      itemCount: widget.videos.length + (widget.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= widget.videos.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return VideoTile(
          video: widget.videos[index],
          onTap: widget.videos[index].videoId == null
              ? null
              : () => widget.onTap(index),
        );
      },
    );
  }
}

class VideoTile extends StatelessWidget {
  const VideoTile({super.key, required this.video, this.onTap});

  final VideoSummary video;
  final VoidCallback? onTap;

  static String formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final d = Duration(seconds: seconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final tile = _buildTile(context);

    // Televizyonda kumandayla geziliyor: hangi öğenin seçili olduğu
    // görünmezse liste kullanılamaz hale geliyor.
    return ValueListenableBuilder<bool>(
      valueListenable: TvMode.isTv,
      builder: (context, isTv, child) =>
          isTv ? _FocusHighlight(onTap: onTap, child: child!) : child!,
      child: tile,
    );
  }

  Widget _buildTile(BuildContext context) {
    return ListTile(
      leading: SizedBox(
        width: 100,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: video.thumbnailUrl == null
              ? Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest)
              : _Thumbnail(url: video.thumbnailUrl!),
        ),
      ),
      title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (video.uploaderName != null) video.uploaderName!,
          formatDuration(video.durationSeconds),
        ].where((e) => e.isNotEmpty).join(' • '),
      ),
      onTap: onTap,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (onRetry != null)
              FilledButton(onPressed: onRetry, child: Text(tr('Tekrar dene', 'Retry'))),
          ],
        ),
      ),
    );
  }
}

/// Odaklanan öğeyi belirgin bir çerçeveyle işaretler (televizyon).
class _FocusHighlight extends StatefulWidget {
  const _FocusHighlight({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_FocusHighlight> createState() => _FocusHighlightState();
}

class _FocusHighlightState extends State<_FocusHighlight> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FocusableActionDetector(
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      // Kumandanın onay tuşu, dokunmayla aynı işi yapar.
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _focused ? scheme.primaryContainer : Colors.transparent,
          border: Border.all(
            color: _focused ? scheme.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: widget.child,
      ),
    );
  }
}

/// Küçük resim; yüklenemezse bir süre sonra YENİDEN dener.
///
/// İnternetsiz açılışta ana sayfa önbellekten gösteriliyor ve resimler
/// yüklenemiyor. Düz `Image.network` bir kez başarısız olunca o satır için
/// bir daha denemiyordu: internet gelse de resim boş kalıyordu.
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.url});

  final String url;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  int _attempt = 0;
  Timer? _retry;

  static const _maxAttempts = 6;
  static const _retryDelay = Duration(seconds: 10);

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _scheduleRetry() {
    if (_retry != null || _attempt >= _maxAttempts) return;
    _retry = Timer(_retryDelay, () {
      _retry = null;
      if (!mounted) return;
      NetworkImage(widget.url).evict();
      setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ThumbImage(
      widget.url,
      key: ValueKey(_attempt),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        _scheduleRetry();
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        );
      },
    );
  }
}
