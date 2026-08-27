import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/playback/ui_channel.dart';
import '../player/player_route.dart';
import 'search_suggestions.dart';
import 'tv_keyboard.dart';
import 'video_list.dart';

/// Televizyonda arama ekranı: solda kumandayla gezilen harf ızgarası, sağda
/// öneriler ve sonuçlar.
///
/// Neden sistem klavyesi kullanılmıyor: Android TV'nin kendi klavyesi
/// ekranın alt yarısını kaplıyor, odak arada uygulamaya geri dönüyor ve
/// kullanıcı yazdığını göremiyordu. Ağaçta odaklanabilir tek düğüm var
/// (kök [Focus]); metin bir [TextField]'da değil düz bir [String]'de
/// tutuluyor, bu yüzden sistem klavyesi HİÇ açılmıyor.
///
/// Tuş haritası:
/// - Sol/Sağ/Yukarı/Aşağı: ızgarada gezinir. Izgaranın sağ kenarından sağa
///   basmak sağdaki listeye geçirir; listede sola basmak ızgaraya döndürür.
/// - OK: ızgarada tuşu uygular, listede öneriyi arar / videoyu oynatır.
/// - Geçmişten gelen bir öneri seçiliyken sağ ok, o satırın "kaldır"
///   düğmesine geçer; OK aramayı geçmişten siler. Ayrı bir düğmeye D-pad
///   ile gitmek yerine satırın kendi içinde kalıyor: televizyonda odak
///   ekranın öbür ucuna atlarsa kullanıcı nerede olduğunu kaybediyor.
/// - Geri: kaldır düğmesindeyken satıra, liste seçiliyken ızgaraya döner,
///   ızgaradayken ekrandan çıkar.
class TvSearchScreen extends StatefulWidget {
  const TvSearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  State<TvSearchScreen> createState() => _TvSearchScreenState();
}

/// Seçim çerçevesi ekranın hangi yarısında.
enum _Pane { keyboard, list }

class _TvSearchScreenState extends State<TvSearchScreen> {
  final _client = ExtractionClient();
  final _focus = FocusNode(debugLabel: 'tvSearch');
  final _listScroll = ScrollController();

  late final SuggestionLoader _loader = SuggestionLoader(
    fetch: (query) => _client.suggestions(query),
  );

  String _query = '';
  _Pane _pane = _Pane.keyboard;
  TvKeyPosition _selection = const TvKeyPosition(0, 0);
  int _listIndex = 0;

  /// Seçili satırın "kaldır" düğmesi mi seçili.
  ///
  /// Yalnızca geçmişten gelen öneri satırlarında anlamlı: kullanıcı
  /// televizyonda eski aramalarını silemiyordu.
  bool _removeSelected = false;

  /// Cihazda ses tanıma varsa mikrofon tuşu çizilir.
  bool _voiceAvailable = false;
  bool _voiceRunning = false;

  /// YouTube'un otomatik tamamlamaları. Geçmişle [SearchSuggestions.merge]
  /// içinde birleşiyor.
  List<String> _remote = const [];

  List<VideoSummary> _results = const [];
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;

  /// Sonuç mu öneri mi gösterildiği.
  ///
  /// Kullanıcı aramadan sonra yazmaya devam ederse sonuçlar bayatlar; o an
  /// yeniden önerilere dönülüyor — YouTube TV de böyle davranıyor.
  bool _showResults = false;

  /// Sonuçların hangi metin için alındığı. Yeniden denemede kullanılıyor.
  String _searchedQuery = '';

  /// Satır yükseklikleri sabit: seçili öğeyi görünür alana kaydırmak için
  /// öğenin nerede olduğunu bilmek gerekiyor.
  static const _suggestionExtent = 56.0;
  static const _resultExtent = 96.0;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery?.trim() ?? '';
    _checkVoice();
    if (_query.isNotEmpty) {
      _runSearch(_query);
    } else {
      _loader.request('', _onRemote);
    }
  }

  @override
  void dispose() {
    _loader.dispose();
    _focus.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  Future<void> _checkVoice() async {
    final available = await UiChannel.instance.isVoiceSearchAvailable();
    if (!mounted) return;
    setState(() => _voiceAvailable = available);
  }

  // ------------------------------------------------------------------ veri

  /// Açık olan klavye sayfası: 0 harfler, 1 rakam/işaret, 2 aksanlı harfler.
  ///
  /// Hepsi tek ızgaraya sığmıyordu; ayrıca yabancı adlar (Beyoncé, Björk)
  /// için aksanlı harfler gerekiyor.
  int _page = 0;

  TvKeyboardLayout get _layout => switch (_page) {
        1 => TvKeyboardLayout.symbols(withVoice: _voiceAvailable),
        2 => TvKeyboardLayout.accents(withVoice: _voiceAvailable),
        _ => TvKeyboardLayout.turkish(withVoice: _voiceAvailable),
      };

  List<String> get _suggestions => SearchSuggestions.merge(
        query: _query,
        history: LibraryStore.instance.searches,
        remote: _remote,
      );

  void _onRemote(List<String> remote) {
    if (!mounted) return;
    setState(() => _remote = remote);
  }

  void _setQuery(String next) {
    if (next == _query) return;
    setState(() {
      _query = next;
      // Yazmaya devam edilince eldeki sonuçlar artık bu metne ait değil.
      _showResults = false;
      _listIndex = 0;
      _removeSelected = false;
    });
    _loader.request(next, _onRemote);
  }

  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _query = trimmed;
      _searchedQuery = trimmed;
      _loading = true;
      _error = null;
      _results = const [];
      _showResults = true;
      _listIndex = 0;
      _removeSelected = false;
      // Arama sonrası kullanıcı sonuçlara bakacak; seçim oraya taşınır.
      _pane = _Pane.list;
    });
    _scrollToSelection();
    try {
      await LibraryStore.instance.recordSearch(trimmed);
      final page = await _client.search(trimmed);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await _client.loadMore(ExtractionClient.kindSearch);
      if (!mounted) return;
      setState(() {
        _results = [..._results, ...page.items];
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Devamı gelmezse eldeki sonuçlar korunur.
      setState(() {
        _hasMore = false;
        _loading = false;
      });
    }
  }

  Future<void> _startVoice() async {
    if (_voiceRunning) return;
    setState(() => _voiceRunning = true);
    final spoken = await UiChannel.instance.startVoiceSearch();
    if (!mounted) return;
    setState(() => _voiceRunning = false);
    // Kullanıcı vazgeçtiyse null döner; yazdığı metin silinmemeli.
    if (spoken == null || spoken.trim().isEmpty) return;
    await _runSearch(spoken);
  }

  void _openResult(int index) {
    final video = _results[index];
    final videoId = video.videoId;
    if (videoId == null) return;
    PlaybackCoordinator.instance.play(videoId, context: _results);
    openPlayer(context, videoId);
  }

  // -------------------------------------------------------------- gezinme

  /// Sağdaki listede kaç öğe var.
  int get _listLength =>
      _showResults ? _results.length : _suggestions.length;

  void _scrollToSelection() {
    if (!_listScroll.hasClients) return;
    final extent = _showResults ? _resultExtent : _suggestionExtent;
    final viewport = _listScroll.position.viewportDimension;
    // Seçili satır ortaya yakın dursun: televizyonda listenin en altındaki
    // satırı seçmek "sıradaki ne" hissini kaybettiriyor.
    final target = (_listIndex * extent) - (viewport / 2) + (extent / 2);
    _listScroll.jumpTo(
      target.clamp(0.0, _listScroll.position.maxScrollExtent),
    );
  }

  void _moveList(int delta) {
    final length = _listLength;
    if (length == 0) return;
    final next = (_listIndex + delta).clamp(0, length - 1);
    if (next == _listIndex) return;
    setState(() {
      _listIndex = next;
      // Satır değişince kaldır düğmesi seçili kalmamalı; kullanıcı yanlışlıkla
      // başka bir aramayı silerdi.
      _removeSelected = false;
    });
    _scrollToSelection();
    // Liste sonuna yaklaşınca devamı yüklensin ki sonuçlar ~20'de bitmesin.
    if (_showResults && _hasMore && next >= _results.length - 3) {
      _loadMore();
    }
  }

  void _pressKey(TvKeyPosition position) {
    final layout = _layout;
    final key = layout.keyAt(layout.clamp(position));
    switch (key.kind) {
      case TvKeyKind.search:
        _runSearch(_query);
      case TvKeyKind.voice:
        _startVoice();
      case TvKeyKind.toggleMode:
        // Üç sayfa sırayla dönüyor. Sayfa değişince seçim ızgaranın dışında
        // kalabilir; sınır içine çekiliyor.
        setState(() {
          _page = (_page + 1) % 3;
          _selection = _layout.clamp(_selection);
        });
      default:
        _setQuery(TvKeyboardLayout.apply(_query, key));
    }
  }

  /// Seçili satır kullanıcının kendi arama geçmişinden mi geliyor.
  ///
  /// Yalnızca bu satırlarda "kaldır" düğmesi var: YouTube'un önerisini
  /// silmek diye bir şey yok.
  String? get _selectedHistoryEntry {
    if (_pane != _Pane.list || _showResults) return null;
    final suggestions = _suggestions;
    if (_listIndex >= suggestions.length) return null;
    final entry = suggestions[_listIndex];
    return SearchSuggestions.isFromHistory(entry, LibraryStore.instance.searches)
        ? entry
        : null;
  }

  Future<void> _removeSelectedHistory() async {
    final entry = _selectedHistoryEntry;
    if (entry == null) return;
    setState(() => _removeSelected = false);
    await LibraryStore.instance.removeSearch(entry);
    if (!mounted) return;
    // Liste kısaldı; seçim taşmasın.
    setState(() {
      final length = _listLength;
      _listIndex = length == 0 ? 0 : _listIndex.clamp(0, length - 1);
      // Son kayıt da silindiyse sağ taraf boş kalıyor; odak orada kalırsa
      // kullanıcı ok tuşlarına basıp hiçbir şeyin oynamadığını görür.
      if (length == 0) _pane = _Pane.keyboard;
    });
  }

  void _activate() {
    if (_pane == _Pane.keyboard) {
      _pressKey(_selection);
      return;
    }
    if (_removeSelected) {
      _removeSelectedHistory();
      return;
    }
    if (_showResults) {
      if (_listIndex < _results.length) _openResult(_listIndex);
      return;
    }
    final suggestions = _suggestions;
    if (_listIndex < suggestions.length) _runSearch(suggestions[_listIndex]);
  }

  /// Geri tuşu: liste seçiliyken ızgaraya döner. Kapatacak bir şey yoksa
  /// false döner ve ekrandan çıkılır.
  bool _handleBack() {
    if (_removeSelected) {
      setState(() => _removeSelected = false);
      return true;
    }
    if (_pane == _Pane.list) {
      setState(() => _pane = _Pane.keyboard);
      return true;
    }
    return false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // const olamıyor: LogicalKeyboardKey kendi == operatörünü tanımlıyor.
    final activate = <LogicalKeyboardKey>{
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.gameButtonA,
    };

    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      return _handleBack() ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    // Bazı kumandalarda mikrofon tuşu ayrı bir tuş kodu gönderiyor.
    if (key == LogicalKeyboardKey.browserSearch) {
      if (_voiceAvailable) _startVoice();
      return KeyEventResult.handled;
    }

    if (activate.contains(key)) {
      _activate();
      return KeyEventResult.handled;
    }

    if (_pane == _Pane.list) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveList(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveList(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        // Geçmiş satırının kaldır düğmesi satırın kendi içinde: odak ekranın
        // öbür ucuna atlamıyor.
        if (!_removeSelected && _selectedHistoryEntry != null) {
          setState(() => _removeSelected = true);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        setState(() {
          if (_removeSelected) {
            _removeSelected = false;
          } else {
            _pane = _Pane.keyboard;
          }
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    final direction = switch (key) {
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;

    final next = _layout.move(_selection, direction);
    if (next != null) {
      setState(() => _selection = next);
    } else if (direction == TraversalDirection.right && _listLength > 0) {
      // Izgaranın sağ kenarından sağa basmak sonuçlara geçirir.
      setState(() {
        _pane = _Pane.list;
        _listIndex = 0;
      });
      _scrollToSelection();
    }
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- çizim

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    // Mikrofon tuşu sonradan eklenip çıkabiliyor; seçim ızgara dışında
    // kalmamalı.
    final selection = layout.clamp(_selection);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_handleBack()) return;
        Navigator.of(context).pop();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: SafeArea(
            child: AnimatedBuilder(
              // Geçmişten öneri silindiğinde/eklendiğinde liste tazelensin.
              animation: LibraryStore.instance,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 420,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _QueryBox(
                            query: _query,
                            listening: _voiceRunning,
                          ),
                          const SizedBox(height: 16),
                          TvKeyboard(
                            layout: layout,
                            selection: selection,
                            active: _pane == _Pane.keyboard,
                            onTap: _pressKey,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(child: _buildRightPane()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRightPane() {
    if (_showResults) return _buildResults();
    return _buildSuggestions();
  }

  Widget _buildSuggestions() {
    final suggestions = _suggestions;
    final history = LibraryStore.instance.searches;
    final title = _query.trim().isEmpty ? 'Son aramalar' : 'Öneriler';

    if (suggestions.isEmpty) {
      return const Center(child: Text('Aramak için harfleri seç.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        Expanded(
          child: ListView.builder(
            controller: _listScroll,
            itemExtent: _suggestionExtent,
            itemCount: suggestions.length,
            itemBuilder: (context, index) {
              final suggestion = suggestions[index];
              final fromHistory =
                  SearchSuggestions.isFromHistory(suggestion, history);
              final rowSelected = _pane == _Pane.list && _listIndex == index;
              return _SelectableRow(
                // Satırın kendisi seçili değilken bile çerçeve kaybolmasın:
                // kaldır düğmesindeyken hangi aramanın silineceği görünmeli.
                selected: rowSelected,
                onTap: () => _runSearch(suggestion),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(fromHistory ? Icons.history : Icons.search, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        suggestion,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    if (fromHistory) ...[
                      // İpucu yalnızca seçili satırda: kullanıcı silmenin
                      // nasıl yapılacağını ekranda görsün.
                      if (rowSelected && !_removeSelected)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            'Kaldırmak için ▶',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                      _RemoveButton(
                        selected: rowSelected && _removeSelected,
                        onTap: () {
                          setState(() {
                            _pane = _Pane.list;
                            _listIndex = index;
                            _removeSelected = true;
                          });
                          _removeSelectedHistory();
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_error != null && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text('${_error!}', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            const Text('Tekrar denemek için "Ara" tuşuna bas.'),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : const Text('Sonuç bulunamadı.'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '"$_searchedQuery" sonuçları',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _listScroll,
            itemExtent: _resultExtent,
            itemCount: _results.length,
            itemBuilder: (context, index) => _SelectableRow(
              selected: _pane == _Pane.list && _listIndex == index,
              onTap: () => _openResult(index),
              child: _ResultRow(video: _results[index]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Yazılan metnin gösterildiği kutu.
///
/// [TextField] DEĞİL: televizyonda odaklanan bir metin alanı sistem
/// klavyesini açıyor, asıl kaçındığımız şey de o.
class _QueryBox extends StatelessWidget {
  const _QueryBox({required this.query, required this.listening});

  final String query;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(listening ? Icons.mic : Icons.search, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              listening
                  ? 'Dinleniyor...'
                  : (query.isEmpty ? 'Video ara...' : query),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 24,
                color: query.isEmpty || listening
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sağdaki listenin bir satırı; seçiliyken belirgin çerçeve alır.
class _SelectableRow extends StatelessWidget {
  const _SelectableRow({
    required this.selected,
    required this.child,
    this.onTap,
  });

  final bool selected;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 3,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }
}

/// Geçmiş satırındaki "kaldır" düğmesi.
///
/// Kumandayla satırdan sağ ok ile geliniyor; seçiliyken televizyon
/// mesafesinden ayırt edilebilsin diye dolu bir daire olarak çiziliyor.
class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.selected, this.onTap});

  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Geçmişten kaldır',
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? scheme.error : Colors.transparent,
            border: Border.all(
              color: selected ? scheme.onError : scheme.outlineVariant,
              width: 2,
            ),
          ),
          child: Icon(
            Icons.close,
            size: 20,
            color: selected ? scheme.onError : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Sonuç satırı.
///
/// [VideoTile] yerine ayrı bir satır: o widget televizyonda kendi odak
/// çerçevesini kuruyor ve bu ekranda odak elle yönetiliyor — iki mekanizma
/// birbiriyle çakışırdı. Süre biçimlendirmesi ortak kalıyor.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.video});

  final VideoSummary video;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [
      if (video.uploaderName != null) video.uploaderName!,
      VideoTile.formatDuration(video.durationSeconds),
    ].where((e) => e.isNotEmpty).join(' • ');

    return Row(
      children: [
        const SizedBox(width: 8),
        SizedBox(
          width: 128,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: video.thumbnailUrl == null
                ? Container(color: scheme.surfaceContainerHighest)
                : Image.network(video.thumbnailUrl!, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                video.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}
