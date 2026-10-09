import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/extraction_client.dart';
import '../../core/extraction/models.dart';
import '../../core/playback/playback_coordinator.dart';
import '../../core/playback/ui_channel.dart';
import '../../core/ui/tv_mode.dart';
import '../library/download_progress_bar.dart';
import '../player/mini_player.dart';
import '../player/player_route.dart';
import 'search_suggestions.dart';
import 'tv_search_screen.dart';
import 'channel_screen.dart';
import 'playlist_screen.dart';
import 'video_list.dart';

/// Arama ekranı.
///
/// Oynatma ekranından da açılabildiği için ayrı bir ekran: kullanıcı müzik
/// dinlerken yeni bir şey aramak için geri gitmek zorunda kalmaz.
///
/// Cihaza göre iki ayrı ekran var. Televizyonda sistem klavyesi kumandayla
/// kullanılamıyordu (bkz. [TvSearchScreen]); telefonda ise dokunmatik klavye
/// zaten doğru araç.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  Widget build(BuildContext context) {
    // Cihaz türü açılışta bir kez belirleniyor ve çalışma sırasında
    // değişmiyor (bkz. [TvMode]); dinlemeye gerek yok.
    return TvMode.isTv.value
        ? TvSearchScreen(initialQuery: initialQuery)
        : PhoneSearchScreen(initialQuery: initialQuery);
  }
}

/// Dokunmatik arama ekranı: sistem klavyesi, yazdıkça öneriler, mikrofon.
class PhoneSearchScreen extends StatefulWidget {
  const PhoneSearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  State<PhoneSearchScreen> createState() => _PhoneSearchScreenState();
}

class _PhoneSearchScreenState extends State<PhoneSearchScreen>
    with SingleTickerProviderStateMixin {
  /// Sekme denetleyicisi durumda tutuluyor: her `setState`'te yeniden
  /// kurulsaydı (ör. `DefaultTabController`) sonuç geldikçe seçili sekme
  /// "Videolar"a geri sıçrardı.
  ///
  /// `late final ... = ...` DEĞİL: hiç arama yapılmayan bir ekranda alan hiç
  /// okunmuyor ve ilk okuma `dispose` içinde oluyordu — widget ağacı
  /// kapanırken denetleyici kurulmaya çalışılınca test ortamı hata veriyordu.
  late final TabController _tabs;

  final _client = ExtractionClient();
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  final _focusNode = FocusNode();

  late final SuggestionLoader _loader = SuggestionLoader(
    fetch: (query) => _client.suggestions(query),
  );

  /// YouTube'un otomatik tamamlamaları; geçmişle birlikte gösteriliyor.
  List<String> _remote = const [];

  /// Cihazda ses tanıma varsa mikrofon düğmesi çizilir.
  bool _voiceAvailable = false;
  bool _voiceRunning = false;

  List<VideoSummary> _results = const [];
  /// Listeler ve kanallar sekmeleri KENDİ aramalarını yapıyor.
  ///
  /// Genel arama kanal döndürmüyor, listelerden de bir ikisini veriyor
  /// (bkz. `ExtractionService.searchFiltered`). Her arama için üç istek atmak
  /// yerine, istek sekmeye ilk dokunulduğunda yapılıyor — sekmelerin çoğu hiç
  /// açılmıyor.
  List<PlaylistSummary> _playlists = const [];
  bool _playlistsLoading = false;
  bool _playlistsLoaded = false;

  List<ChannelSummary> _channels = const [];
  bool _channelsLoading = false;
  bool _channelsLoaded = false;
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;
  bool _searched = false;

  /// Sonuçların hangi metin için alındığı.
  ///
  /// Kullanıcı aramadan sonra yazmaya devam ederse eldeki sonuçlar artık o
  /// metne ait değil; o an yeniden önerilere dönülüyor.
  String? _searchedQuery;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)
      ..addListener(_onTabChanged);
    _controller.addListener(_onQueryChanged);
    _checkVoice();
    final initial = widget.initialQuery;
    if (initial != null && initial.trim().isNotEmpty) {
      _search(initial);
    } else {
      // Arama için açıldıysa klavye hemen gelsin.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusNode.requestFocus());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focusNode.dispose();
    _loader.dispose();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _checkVoice() async {
    final available = await UiChannel.instance.isVoiceSearchAvailable();
    if (!mounted) return;
    setState(() => _voiceAvailable = available);
  }

  /// Öneri listesi mi, sonuç listesi mi gösterilecek.
  bool get _showSuggestions =>
      _searchedQuery == null || _controller.text.trim() != _searchedQuery;

  void _onQueryChanged() {
    _loader.request(_controller.text, (remote) {
      if (!mounted) return;
      setState(() => _remote = remote);
    });
    // Metin değişince öneri/sonuç seçimi de değişebilir.
    setState(() {});
  }

  Future<void> _startVoice() async {
    if (_voiceRunning) return;
    setState(() => _voiceRunning = true);
    final spoken = await UiChannel.instance.startVoiceSearch();
    if (!mounted) return;
    setState(() => _voiceRunning = false);
    // Kullanıcı vazgeçtiyse null döner; yazdığı metin silinmemeli.
    if (spoken == null || spoken.trim().isEmpty) return;
    _controller.text = spoken.trim();
    await _search(spoken);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
      _results = const [];
      _playlists = const [];
      _playlistsLoaded = false;
      // Önceki aramanın yüklemesi hâlâ sürüyorsa sonucu atılacak; bayrak
      // burada sıfırlanmazsa yeni aramanın sekmesi sonsuza dek "yükleniyor".
      _playlistsLoading = false;
      _channels = const [];
      _channelsLoaded = false;
      _channelsLoading = false;
      _searchedQuery = query.trim();
    });
    try {
      final trimmed = query.trim();
      await LibraryStore.instance.recordSearch(trimmed);
      final page = await _client.search(trimmed);
      // Arka arkaya iki arama: geç dönen eski sonuç yenisinin üzerine yazmasın.
      if (!mounted || _searchedQuery != trimmed) return;
      setState(() {
        _results = page.items;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // Kullanıcı arama sırasında başka bir sekmede duruyorsa onu da doldur.
      _loadTabIfNeeded(_tabs.index);
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
      // Devamı gelmezse eldeki sonuçlar korunur; kullanıcıya boş ekran
      // gösterip mevcut listeyi kaybetmiyoruz.
      setState(() {
        _hasMore = false;
        _loading = false;
      });
    }
  }

  void _open(int index) {
    // Arama sonuçları kuyruğa KAYNAK OLARAK VERİLMİYOR.
    //
    // Bir şarkı arandığında sonuçların tamamı o şarkının başka sürümleri
    // oluyor (remiks, hızlandırılmış, kapak, "(Joker)", "(Obiymy)"…); bu
    // havuzdan kurulan kuyruk baştan sona aynı şarkıyı çalıyordu. Gerçek
    // cihazda "la calin" araması on sonucun onunu da aynı parçayla döndürdü.
    //
    // Kuyruk bunun yerine videonun KENDİ ilgili videolarından kuruluyor —
    // YouTube'un otomatik oynatmasının da beslendiği kaynak. Ana sayfa ve
    // kitaplık listeleri bağlamı vermeye devam ediyor; oralarda liste
    // gerçekten çeşitli ve kuyruğa katkısı oluyor.
    PlaybackCoordinator.instance.play(_results[index].videoId!);
    openPlayer(context, _results[index].videoId!);
  }

  void _openPlaylist(PlaylistSummary playlist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaylistScreen(playlist: playlist),
      ),
    );
  }

  void _onTabChanged() {
    // Kaydırma sırasında iki kez tetikleniyor; yalnızca yerleşen sekme
    // için istek atıyoruz.
    if (_tabs.indexIsChanging) return;
    _loadTabIfNeeded(_tabs.index);
  }

  void _loadTabIfNeeded(int index) {
    final query = _searchedQuery;
    if (query == null) return;
    if (index == 1 && !_playlistsLoaded && !_playlistsLoading) {
      _loadPlaylists(query);
    } else if (index == 2 && !_channelsLoaded && !_channelsLoading) {
      _loadChannels(query);
    }
  }

  Future<void> _loadPlaylists(String query) async {
    setState(() => _playlistsLoading = true);
    try {
      final page = await _client.searchFiltered(
        query,
        ExtractionClient.kindSearchPlaylists,
      );
      if (!mounted || _searchedQuery != query) return;
      setState(() {
        _playlists = page.playlists;
        _playlistsLoaded = true;
        _playlistsLoading = false;
      });
    } catch (_) {
      if (!mounted || _searchedQuery != query) return;
      // Boş liste gösteriliyor: ayrı bir hata ekranı kurmak yerine
      // "bulunamadı" mesajı yeterli, kullanıcı aramayı tekrarlayabilir.
      setState(() {
        _playlistsLoaded = true;
        _playlistsLoading = false;
      });
    }
  }

  Future<void> _loadChannels(String query) async {
    setState(() => _channelsLoading = true);
    try {
      final page = await _client.searchFiltered(
        query,
        ExtractionClient.kindSearchChannels,
      );
      if (!mounted || _searchedQuery != query) return;
      setState(() {
        _channels = page.channels;
        _channelsLoaded = true;
        _channelsLoading = false;
      });
    } catch (_) {
      if (!mounted || _searchedQuery != query) return;
      setState(() {
        _channelsLoaded = true;
        _channelsLoading = false;
      });
    }
  }

  void _openChannel(ChannelSummary channel) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChannelScreen(channel: channel)),
    );
  }

  void _pick(String query) {
    _controller.text = query;
    _search(query);
  }

  /// Arama sonuçları: videolar ve çalma listeleri ayrı sekmelerde.
  ///
  /// YouTube ikisini tek listede karışık veriyor; ayırmak, "şarkı mı liste mi
  /// arıyorum" sorusunu kullanıcının her satırda yeniden sormasını önlüyor.
  Widget _buildResults() {
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: [
            const Tab(text: 'Videolar'),
            Tab(
              // Sayı sekmenin üstünde: kullanıcı dokunmadan önce orada bir
              // şey olup olmadığını görüyor.
              text: _playlists.isEmpty
                  ? 'Listeler'
                  : 'Listeler (${_playlists.length})',
            ),
            Tab(
              text: _channels.isEmpty
                  ? 'Kanallar'
                  : 'Kanallar (${_channels.length})',
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              VideoList(
                videos: _results,
                loading: _loading,
                hasMore: _hasMore,
                error: _error,
                emptyMessage: 'Sonuç bulunamadı.',
                onRetry: () => _search(_controller.text),
                onLoadMore: _loadMore,
                onTap: _open,
              ),
              _PlaylistResults(
                playlists: _playlists,
                loading: _playlistsLoading,
                onTap: _openPlaylist,
              ),
              _ChannelResults(
                channels: _channels,
                loading: _channelsLoading,
                onTap: _openChannel,
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Video ara...',
            border: InputBorder.none,
          ),
          onSubmitted: _search,
        ),
        actions: [
          // Ses tanıma olmayan cihazda düğme HİÇ çizilmez: basınca bir şey
          // olmayan düğme, olmayan düğmeden kötü.
          if (_voiceAvailable)
            IconButton(
              icon: Icon(_voiceRunning ? Icons.mic : Icons.mic_none),
              tooltip: 'Sesle ara',
              onPressed: _voiceRunning ? null : _startVoice,
            ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(_controller.text),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _showSuggestions
                ? _SuggestionList(
                    query: _controller.text,
                    remote: _remote,
                    onPick: _pick,
                  )
                : _searched
                    ? _buildResults()
                    : VideoList(
                        videos: const [],
                        loading: false,
                        hasMore: false,
                        emptyMessage: 'Aramak için yazmaya başla.',
                        onLoadMore: () {},
                        onTap: (_) {},
                      ),
          ),
          const DownloadProgressBar(),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

/// Arama kutusunun altındaki öneriler: önce kullanıcının geçmişi, sonra
/// YouTube'un otomatik tamamlamaları.
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({
    required this.query,
    required this.remote,
    required this.onPick,
  });

  final String query;
  final List<String> remote;
  final void Function(String query) onPick;

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final history = store.searches;
        final suggestions = SearchSuggestions.merge(
          query: query,
          history: history,
          remote: remote,
        );
        if (suggestions.isEmpty) {
          return const Center(child: Text('Aramak için yazmaya başla.'));
        }
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                query.trim().isEmpty ? 'Son aramalar' : 'Öneriler',
              ),
            ),
            for (final suggestion in suggestions)
              if (SearchSuggestions.isFromHistory(suggestion, history))
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(suggestion),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => store.removeSearch(suggestion),
                  ),
                  onTap: () => onPick(suggestion),
                )
              else
                ListTile(
                  leading: const Icon(Icons.search),
                  title: Text(suggestion),
                  onTap: () => onPick(suggestion),
                ),
          ],
        );
      },
    );
  }
}

/// "Listeler" sekmesinin içeriği.
class _PlaylistResults extends StatelessWidget {
  const _PlaylistResults({
    required this.playlists,
    required this.loading,
    required this.onTap,
  });

  final List<PlaylistSummary> playlists;
  final bool loading;
  final void Function(PlaylistSummary) onTap;

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      // Yükleme sürerken "liste yok" demek yanlış olurdu; sonuçlar iki
      // listeye aynı anda geliyor.
      if (loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Bu aramada çalma listesi bulunamadı.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: playlists.length,
      itemBuilder: (context, index) => PlaylistTile(
        playlist: playlists[index],
        onTap: () => onTap(playlists[index]),
      ),
    );
  }
}

/// "Kanallar" sekmesinin içeriği.
class _ChannelResults extends StatelessWidget {
  const _ChannelResults({
    required this.channels,
    required this.loading,
    required this.onTap,
  });

  final List<ChannelSummary> channels;
  final bool loading;
  final void Function(ChannelSummary) onTap;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      if (loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Bu aramada kanal bulunamadı.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: channels.length,
      itemBuilder: (context, index) => ChannelTile(
        channel: channels[index],
        onTap: () => onTap(channels[index]),
      ),
    );
  }
}
