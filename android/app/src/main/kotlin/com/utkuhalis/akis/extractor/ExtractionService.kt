package com.utkuhalis.akis.extractor

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.ListExtractor
import org.schabi.newpipe.extractor.ListExtractor.InfoItemsPage
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.Page
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
import org.schabi.newpipe.extractor.stream.StreamType
import org.schabi.newpipe.extractor.stream.VideoStream

/**
 * Flutter tarafına sunulan tüm "reklamsız YouTube verisi" burada toplanır.
 * Hiçbir metodun UI/ana thread'de çalıştırılmaması için hepsi `suspend` ve
 * IO dispatcher'ında koşuyor — bu sayede Flutter tarafı asla donmaz.
 */
object ExtractionService {

    private var initialized = false

    @Synchronized
    private fun ensureInitialized() {
        if (!initialized) {
            NewPipe.init(OkHttpDownloader.getInstance())
            initialized = true
        }
    }

    /**
     * Sayfalanabilir bir liste (arama sonucu / trend) için açık oturum.
     *
     * YouTube tek istekte yalnızca ~20 sonuç döndürür; devamı ancak aynı
     * extractor üzerinden [ListExtractor.getPage] ile alınabilir. Bu yüzden
     * extractor'ı ve bir sonraki sayfa işaretçisini burada saklıyoruz.
     */
    private class PagedSession(val extractor: ListExtractor<*>) {
        var nextPage: Page? = null
    }

    // Türü başına tek oturum: yeni bir arama öncekinin yerini alır, böylece
    // oturumlar birikip bellek sızdırmaz.
    private val sessions = mutableMapOf<String, PagedSession>()

    private fun InfoItemsPage<*>.toResult(session: PagedSession): Map<String, Any?> {
        session.nextPage = nextPage
        return mapOf(
            "items" to items.filterIsInstance<StreamInfoItem>().map { it.toMap() },
            "hasMore" to hasNextPage()
        )
    }

    suspend fun search(query: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val extractor = ServiceList.YouTube.getSearchExtractor(query)
        extractor.fetchPage()
        val session = PagedSession(extractor)
        sessions[KIND_SEARCH] = session
        extractor.initialPage.toResult(session)
    }

    suspend fun trending(): Map<String, Any?> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val kioskList = ServiceList.YouTube.kioskList
        // getDefaultKioskExtractor() overload'lu olduğu için Kotlin property
        // sentezini garanti etmemek adına açık metod çağrısı kullanıyoruz.
        val extractor = kioskList.getDefaultKioskExtractor()
        extractor.fetchPage()
        val session = PagedSession(extractor)
        sessions[KIND_TRENDING] = session
        extractor.initialPage.toResult(session)
    }

    /**
     * Açık oturumun bir sonraki sayfasını getirir. Oturum yoksa ya da son
     * sayfaya gelinmişse boş sonuç döner — çağıran taraf sonsuz kaydırmayı
     * güvenle durdurabilir.
     */
    suspend fun loadMore(kind: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val session = sessions[kind]
        val page = session?.nextPage
        if (session == null || page == null) {
            return@withContext mapOf("items" to emptyList<Any?>(), "hasMore" to false)
        }
        session.extractor.getPage(page).toResult(session)
    }

    /**
     * Bir YouTube çalma listesinin başlığı ve videoları.
     *
     * Uzun listelerde ilk sayfa yeterli olmadığı için oturum saklanır ve
     * devamı [loadMore] ile ([KIND_PLAYLIST]) alınabilir.
     */
    suspend fun playlist(playlistUrl: String): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            ensureInitialized()
            val extractor = ServiceList.YouTube.getPlaylistExtractor(playlistUrl)
            extractor.fetchPage()
            val session = PagedSession(extractor)
            sessions[KIND_PLAYLIST] = session
            val page = extractor.initialPage
            session.nextPage = page.nextPage
            mapOf(
                "title" to extractor.name,
                "uploaderName" to extractor.uploaderName,
                "streamCount" to extractor.streamCount,
                "items" to page.items.filterIsInstance<StreamInfoItem>().map { it.toMap() },
                "hasMore" to page.hasNextPage()
            )
        }

    /**
     * Ham [StreamInfo]. Oynatıcı, kuyrukta sıradakine geçerken kaynakları
     * kendisi seçebilmek için buna ihtiyaç duyar (bkz. [StreamSelector]).
     */
    fun streamInfo(videoId: String): StreamInfo {
        ensureInitialized()
        return StreamInfo.getInfo(
            ServiceList.YouTube,
            "https://www.youtube.com/watch?v=$videoId"
        )
    }

    suspend fun videoDetails(videoId: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val url = "https://www.youtube.com/watch?v=$videoId"
        val info = StreamInfo.getInfo(ServiceList.YouTube, url)

        mapOf(
            "videoId" to videoId,
            "title" to info.name,
            "uploaderName" to info.uploaderName,
            "uploaderUrl" to info.uploaderUrl,
            "durationSeconds" to info.duration,
            "viewCount" to info.viewCount,
            "description" to (info.description?.content ?: ""),
            // Kategori, içeriğin müzik mi yoksa izlenecek bir video mu olduğunu
            // ayırt etmek için kullanılıyor (bkz. Dart tarafındaki içerik türü tespiti).
            "category" to info.category,
            "tags" to info.tags,
            // Canlı yayınlarda ayrık progressive stream bulunmaz; oynatma
            // HLS manifesti üzerinden yapılmalıdır.
            "isLive" to (info.streamType == StreamType.LIVE_STREAM ||
                info.streamType == StreamType.AUDIO_LIVE_STREAM),
            "thumbnailUrl" to info.thumbnails.bestThumbnailUrl(),
            "hlsUrl" to info.hlsUrl,
            "dashMpdUrl" to info.dashMpdUrl,
            "videoStreams" to info.videoStreams.map { it.toMap() },
            "videoOnlyStreams" to info.videoOnlyStreams.map { it.toMap() },
            "audioStreams" to info.audioStreams.map { it.toMap() },
            "relatedItems" to info.relatedItems
                .filterIsInstance<StreamInfoItem>()
                .map { it.toMap() }
        )
    }

    private fun StreamInfoItem.toMap(): Map<String, Any?> = mapOf(
        "videoId" to extractVideoId(url),
        "title" to name,
        "url" to url,
        "uploaderName" to uploaderName,
        "durationSeconds" to duration,
        "viewCount" to viewCount,
        "textualUploadDate" to textualUploadDate,
        "thumbnailUrl" to thumbnails.bestThumbnailUrl()
    )

    private fun VideoStream.toMap(): Map<String, Any?> = mapOf(
        "url" to content,
        "resolution" to resolution,
        "format" to format?.name,
        "isVideoOnly" to isVideoOnly,
        "fps" to fps,
        "bitrate" to bitrate
    )

    private fun AudioStream.toMap(): Map<String, Any?> = mapOf(
        "url" to content,
        "format" to format?.name,
        "averageBitrate" to averageBitrate
    )

    private fun List<org.schabi.newpipe.extractor.Image>.bestThumbnailUrl(): String? =
        maxByOrNull { it.height * it.width }?.url

    private fun extractVideoId(videoUrl: String): String? =
        Regex("[?&]v=([^&]+)").find(videoUrl)?.groupValues?.get(1)
            ?: videoUrl.substringAfterLast("/").takeIf { it.isNotBlank() }

    const val KIND_SEARCH = "search"
    const val KIND_TRENDING = "trending"
    const val KIND_PLAYLIST = "playlist"
}
