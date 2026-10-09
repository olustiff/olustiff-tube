package com.olustiff.app.extractor

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.ListExtractor
import org.schabi.newpipe.extractor.ListExtractor.InfoItemsPage
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.Page
import org.schabi.newpipe.extractor.services.youtube.linkHandler.YoutubeSearchQueryHandlerFactory
import org.schabi.newpipe.extractor.channel.ChannelInfo
import org.schabi.newpipe.extractor.channel.ChannelInfoItem
import org.schabi.newpipe.extractor.channel.tabs.ChannelTabs
import org.schabi.newpipe.extractor.playlist.PlaylistInfoItem
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

    /**
     * Bir sayfayı Flutter'a geçilecek biçime çevirir.
     *
     * Videolar ve çalma listeleri AYRI iki liste olarak dönüyor. YouTube arama
     * sonucunda ikisini karışık veriyor; tek listede birleştirmek arayüzde
     * "video mu liste mi" ayrımını her satırda yapmayı gerektirirdi. Kanal
     * sonuçları hâlâ atılıyor — onlar için bir ekran yok.
     */
    private fun InfoItemsPage<*>.toResult(session: PagedSession): Map<String, Any?> {
        session.nextPage = nextPage
        return mapOf(
            "items" to items.filterIsInstance<StreamInfoItem>().map { it.toMap() },
            "playlists" to items.filterIsInstance<PlaylistInfoItem>().map { it.toMap() },
            "channels" to items.filterIsInstance<ChannelInfoItem>().map { it.toMap() },
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

    /**
     * Yalnızca çalma listelerini ya da yalnızca kanalları arar.
     *
     * Neden ayrı bir istek: YouTube'un "tümü" araması pratikte kanal
     * DÖNDÜRMÜYOR (gerçek cihazda "raikaho" araması tek bir kanal bile
     * vermedi) ve çalma listelerinden de yalnızca bir ikisini araya
     * serpiştiriyor. Filtreli arama aynı sorguyu YouTube'un o türe ayrılmış
     * sonuç sayfasına soruyor ve dolu bir liste dönüyor.
     *
     * İstek, kullanıcı o sekmeye DOKUNDUĞUNDA yapılıyor: her aramada üç
     * istek birden atmak, sekmelerin çoğunun hiç açılmadığı düşünülürse
     * gereksiz.
     */
    suspend fun searchFiltered(query: String, kind: String): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            ensureInitialized()
            val filter = when (kind) {
                KIND_SEARCH_CHANNELS -> YoutubeSearchQueryHandlerFactory.CHANNELS
                else -> YoutubeSearchQueryHandlerFactory.PLAYLISTS
            }
            val extractor = ServiceList.YouTube.getSearchExtractor(
                query,
                listOf(filter),
                ""
            )
            extractor.fetchPage()
            val session = PagedSession(extractor)
            sessions[kind] = session
            extractor.initialPage.toResult(session)
        }

    /**
     * Arama kutusuna yazarken YouTube'un önerdiği tamamlamalar.
     *
     * Sayfalanabilir listelerden farklı olarak oturum TUTULMAZ: kullanıcı
     * yazdıkça peş peşe istek geliyor, saklanan bir oturum hemen eskiyeceği
     * için yalnızca bellek işgal ederdi.
     */
    suspend fun suggestions(query: String): List<String> = withContext(Dispatchers.IO) {
        ensureInitialized()
        if (query.isBlank()) {
            return@withContext emptyList()
        }
        ServiceList.YouTube.suggestionExtractor.suggestionList(query)
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
     * Bir kanalın videoları.
     *
     * Kanal videoları doğrudan kanal çıkarıcısından GELMİYOR: NewPipe bunları
     * "sekme"lere ayırdı (Videolar, Shorts, Oynatma listeleri…). Bize gereken
     * sekme seçilip onun çıkarıcısı kullanılıyor.
     *
     * Sekme tercihi sırayla: önce normal videolar, yoksa parçalar (müzik
     * kanallarında videolar sekmesi olmuyor, "Tracks" oluyor), o da yoksa
     * elde ne varsa ilki. Boş liste döndürmektense yanlış sekmeyi
     * göstermemek için sırayı bu şekilde tutuyoruz.
     *
     * Devamı [loadMore] ile ([KIND_CHANNEL]) alınıyor.
     */
    suspend fun channel(channelUrl: String): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            ensureInitialized()
            val service = ServiceList.YouTube
            val info = ChannelInfo.getInfo(service, channelUrl)

            val tab = info.tabs.firstOrNull {
                it.contentFilters.contains(ChannelTabs.VIDEOS)
            } ?: info.tabs.firstOrNull {
                it.contentFilters.contains(ChannelTabs.TRACKS)
            } ?: info.tabs.firstOrNull()

            if (tab == null) {
                // Kanalın gösterilebilir sekmesi yok; künyeyi yine de
                // döndürüyoruz ki ekran boş bir hata yerine kanalı gösterebilsin.
                return@withContext mapOf(
                    "name" to info.name,
                    "subscriberCount" to info.subscriberCount,
                    "avatarUrl" to info.avatars.bestThumbnailUrl(),
                    "items" to emptyList<Map<String, Any?>>(),
                    "hasMore" to false
                )
            }

            val extractor = service.getChannelTabExtractor(tab)
            extractor.fetchPage()
            val session = PagedSession(extractor)
            sessions[KIND_CHANNEL] = session
            val page = extractor.initialPage
            session.nextPage = page.nextPage
            mapOf(
                "name" to info.name,
                "subscriberCount" to info.subscriberCount,
                "avatarUrl" to info.avatars.bestThumbnailUrl(),
                "items" to page.items.filterIsInstance<StreamInfoItem>()
                    .map { it.toMap() },
                "hasMore" to page.hasNextPage()
            )
        }

    /**
     * Ham [StreamInfo]. Oynatıcı, kuyrukta sıradakine geçerken kaynakları
     * kendisi seçebilmek için buna ihtiyaç duyar (bkz. [StreamSelector]).
     */
    /**
     * Bir videonun çözümlenmiş bilgisi — kısa ömürlü ÖNBELLEKLİ.
     *
     * Önbellek bir hız iyileştirmesi değil, bir DOĞRULUK düzeltmesi.
     *
     * Aynı video kuyruk ilerlerken iki kez çözülüyordu: native taraf çalmak
     * için ([PlayerHolder.playQueueItem]), Dart tarafı da ekranı doldurmak
     * için ([videoDetails]). İki çözümleme farklı YouTube istemcilerine
     * düşebiliyor ve ürettikleri akış adresleri birbirinin yerine
     * KULLANILAMIYOR — oynatıcının gönderdiği kimlikle uyuşmayan adres
     * reddediliyor.
     *
     * Bu, gerçek cihazda şöyle patladı: kullanıcı sesli moda geçiyor, Dart
     * kendi çözümlemesinden gelen adresi veriyor, sunucu
     * `ERROR_CODE_IO_BAD_HTTP_STATUS` dönüyor ve oynatıcı hata durumunda
     * kalıyor. Tek bir çözümlemeyi paylaşmak bu uyuşmazlığı kökten kaldırıyor;
     * yan fayda olarak her parça geçişindeki ağ yükü de yarıya iniyor.
     *
     * Ömür kısa tutuluyor: YouTube adresleri zamanla geçersizleşiyor,
     * bayat bir kaydı paylaşmak sorunu çözmek yerine yayardı.
     */
    private class CachedStream(val info: StreamInfo, val fetchedAt: Long)

    private val streamCache = LinkedHashMap<String, CachedStream>()

    @Synchronized
    private fun cached(videoId: String): StreamInfo? {
        val entry = streamCache[videoId] ?: return null
        if (System.currentTimeMillis() - entry.fetchedAt > STREAM_CACHE_TTL_MS) {
            streamCache.remove(videoId)
            return null
        }
        return entry.info
    }

    @Synchronized
    private fun remember(videoId: String, info: StreamInfo) {
        streamCache[videoId] = CachedStream(info, System.currentTimeMillis())
        // Yalnızca son birkaç video tutuluyor; bu bir indirme önbelleği değil,
        // "aynı anda iki kez sorulmasın" önlemi.
        while (streamCache.size > STREAM_CACHE_SIZE) {
            streamCache.remove(streamCache.keys.first())
        }
    }

    fun streamInfo(videoId: String): StreamInfo {
        ensureInitialized()
        cached(videoId)?.let { return it }
        val info = StreamInfo.getInfo(
            ServiceList.YouTube,
            "https://www.youtube.com/watch?v=$videoId"
        )
        remember(videoId, info)
        return info
    }

    suspend fun videoDetails(videoId: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val info = cached(videoId) ?: StreamInfo.getInfo(
            ServiceList.YouTube,
            "https://www.youtube.com/watch?v=$videoId"
        ).also { remember(videoId, it) }

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

    /**
     * Çalma listesi sonucu.
     *
     * `streamCount` bilinmiyorsa NewPipe -1 veriyor; Dart tarafı bunu "sayı
     * yok" diye okuyor ve rozet göstermiyor — 0 göstermek listeyi boş
     * sanmaya yol açardı.
     */
    /**
     * Kanal sonucu.
     *
     * Abone ve video sayısını NewPipe bilinmiyorsa -1 veriyor; Dart tarafı
     * bunu "sayı yok" diye okuyup rozeti hiç göstermiyor.
     */
    private fun ChannelInfoItem.toMap(): Map<String, Any?> = mapOf(
        "name" to name,
        "url" to url,
        "subscriberCount" to subscriberCount,
        "streamCount" to streamCount,
        "verified" to isVerified,
        "thumbnailUrl" to thumbnails.bestThumbnailUrl()
    )

    private fun PlaylistInfoItem.toMap(): Map<String, Any?> = mapOf(
        "title" to name,
        "url" to url,
        "uploaderName" to uploaderName,
        "streamCount" to streamCount,
        "thumbnailUrl" to thumbnails.bestThumbnailUrl()
    )

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

    /**
     * Kodek, boyut ve parça baytları da gönderiliyor: "Otomatik" kalitede
     * Dart tarafı bu akışlardan uyarlanabilir bir DASH manifesti kuruyor
     * (bkz. `stream_selection.dart`). Bunlar olmadan oynatıcıya tek bir sabit
     * çözünürlükten başka bir şey verilemez.
     */
    private fun VideoStream.toMap(): Map<String, Any?> = mapOf(
        "url" to content,
        "resolution" to resolution,
        "format" to format?.name,
        "mimeType" to format?.mimeType,
        "isVideoOnly" to isVideoOnly,
        "fps" to fps,
        "bitrate" to bitrate,
        "itag" to itag,
        "codec" to codec,
        "width" to width,
        "height" to height,
        "initStart" to initStart,
        "initEnd" to initEnd,
        "indexStart" to indexStart,
        "indexEnd" to indexEnd
    )

    private fun AudioStream.toMap(): Map<String, Any?> = mapOf(
        "url" to content,
        "format" to format?.name,
        "averageBitrate" to averageBitrate
    )

    private fun List<org.schabi.newpipe.extractor.Image>.bestThumbnailUrl(): String? =
        maxByOrNull { it.height * it.width }?.url

    /** Video adresinden id çıkarır. Kuyruk kurulurken de kullanılıyor. */
    fun extractVideoId(videoUrl: String): String? =
        Regex("[?&]v=([^&]+)").find(videoUrl)?.groupValues?.get(1)
            ?: videoUrl.substringAfterLast("/").takeIf { it.isNotBlank() }

    const val KIND_SEARCH = "search"
    const val KIND_TRENDING = "trending"
    const val KIND_PLAYLIST = "playlist"
    const val KIND_CHANNEL = "channel"
    const val KIND_SEARCH_PLAYLISTS = "search_playlists"
    const val KIND_SEARCH_CHANNELS = "search_channels"

    /** Çözümleme önbelleğinin ömrü. */
    private const val STREAM_CACHE_TTL_MS = 2 * 60 * 1000L

    /** Önbellekte tutulan video sayısı. */
    private const val STREAM_CACHE_SIZE = 4
}
