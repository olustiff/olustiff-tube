package com.utkuhalis.akis.extractor

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.InfoItem
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamInfoItem
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

    suspend fun search(query: String): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val extractor = ServiceList.YouTube.getSearchExtractor(query)
        extractor.fetchPage()
        extractor.initialPage.items
            .filterIsInstance<StreamInfoItem>()
            .map { it.toMap() }
    }

    suspend fun trending(): List<Map<String, Any?>> = withContext(Dispatchers.IO) {
        ensureInitialized()
        val kioskList = ServiceList.YouTube.kioskList
        // getDefaultKioskExtractor() overload'lu olduğu için Kotlin property
        // sentezini garanti etmemek adına açık metod çağrısı kullanıyoruz.
        val extractor = kioskList.getDefaultKioskExtractor()
        extractor.fetchPage()
        extractor.initialPage.items
            .filterIsInstance<StreamInfoItem>()
            .map { it.toMap() }
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
}
