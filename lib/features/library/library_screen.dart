import 'package:flutter/material.dart';

import '../../core/data/library_store.dart';
import '../../core/extraction/models.dart';
import '../../core/i18n/lang.dart';
import '../../core/playback/playback_coordinator.dart';
import '../player/mini_player.dart';
import 'download_progress_bar.dart';
import '../player/player_route.dart';
import '../search/search_screen.dart';
import '../search/video_list.dart';
import 'downloads_tab.dart';

/// Kitaplık: izleme geçmişi, arama geçmişi ve kullanıcının çalma listeleri.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Kitaplık', 'Library')),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: tr('İndirilenler', 'Downloads')),
              Tab(text: tr('Geçmiş', 'History')),
              Tab(text: tr('Listelerim', 'My playlists')),
              Tab(text: tr('Aramalar', 'Searches')),
            ],
          ),
        ),
        body: Column(
          children: [
            const Expanded(
              child: TabBarView(
                children: [
                  DownloadsTab(),
                  _WatchHistoryTab(),
                  _PlaylistsTab(),
                  _SearchHistoryTab(),
                ],
              ),
            ),
            const DownloadProgressBar(),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }
}

class _WatchHistoryTab extends StatelessWidget {
  const _WatchHistoryTab();

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final watched = store.watched;
        if (watched.isEmpty) {
          return Center(
            child: Text(
              tr('Henüz bir şey izlemedin.', "You haven't watched anything yet."),
            ),
          );
        }
        return Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: store.clearWatched,
                icon: const Icon(Icons.delete_outline),
                label: Text(tr('Geçmişi temizle', 'Clear history')),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: watched.length,
                itemBuilder: (context, index) => VideoTile(
                  video: watched[index],
                  onTap: () => _play(context, watched, index),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchHistoryTab extends StatelessWidget {
  const _SearchHistoryTab();

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final searches = store.searches;
        if (searches.isEmpty) {
          return Center(
            child: Text(
              tr('Henüz arama yapmadın.', "You haven't searched for anything yet."),
            ),
          );
        }
        return Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: store.clearSearches,
                icon: const Icon(Icons.delete_outline),
                label: Text(tr('Aramaları temizle', 'Clear searches')),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: searches.length,
                itemBuilder: (context, index) {
                  final query = searches[index];
                  return ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(query),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => store.removeSearch(query),
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SearchScreen(initialQuery: query),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistsTab extends StatelessWidget {
  const _PlaylistsTab();

  Future<void> _createPlaylist(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Yeni çalma listesi', 'New playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: tr('Liste adı', 'Playlist name'),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Vazgeç', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(tr('Oluştur', 'Create')),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await LibraryStore.instance.createPlaylist(name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final playlists = store.playlists;
        return Scaffold(
          body: playlists.isEmpty
              ? Center(
                  child: Text(
                    tr('Henüz çalma listen yok.', 'No playlists yet.'),
                  ),
                )
              : ListView(
                  children: [
                    for (final entry in playlists.entries)
                      ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: Text(entry.key),
                        subtitle: Text(tr(
                          '${entry.value.length} video',
                          entry.value.length == 1
                              ? '1 video'
                              : '${entry.value.length} videos',
                        )),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => store.deletePlaylist(entry.key),
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _PlaylistScreen(name: entry.key),
                          ),
                        ),
                      ),
                  ],
                ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _createPlaylist(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

class _PlaylistScreen extends StatelessWidget {
  const _PlaylistScreen({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final videos = store.playlists[name] ?? const <VideoSummary>[];
        return Scaffold(
          appBar: AppBar(title: Text(name)),
          body: Column(
            children: [
              Expanded(
                child: videos.isEmpty
                    ? Center(
                        child: Text(
                          tr('Bu liste boş.', 'This playlist is empty.'),
                        ),
                      )
                    : ListView.builder(
                        itemCount: videos.length,
                        itemBuilder: (context, index) => Dismissible(
                          key: ValueKey(videos[index].videoId),
                          onDismissed: (_) => store.removeFromPlaylist(
                              name, videos[index].videoId!),
                          background: Container(color: Colors.red),
                          child: VideoTile(
                            video: videos[index],
                            // Çalma listesinin sırası kullanıcıya ait;
                            // karıştırılmadan olduğu gibi çalınır.
                            onTap: () => _play(context, videos, index,
                                exact: true),
                          ),
                        ),
                      ),
              ),
              const DownloadProgressBar(),
              const MiniPlayer(),
            ],
          ),
        );
      },
    );
  }
}

void _play(
  BuildContext context,
  List<VideoSummary> list,
  int index, {
  bool exact = false,
}) {
  final videoId = list[index].videoId;
  if (videoId == null) return;
  PlaybackCoordinator.instance.play(
    videoId,
    context: exact ? const [] : list,
    exactQueue: exact ? list : null,
    index: exact ? index : null,
  );
  openPlayer(context, videoId);
}
