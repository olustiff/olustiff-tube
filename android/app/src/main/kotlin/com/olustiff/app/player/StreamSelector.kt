package com.olustiff.app.player

import com.olustiff.app.Lang
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.StreamType
import org.schabi.newpipe.extractor.stream.VideoStream

/**
 * Bir videonun hangi kaynaklardan oynatılacağını seçer.
 *
 * Neden native tarafta: sıradaki parçaya geçiş ekran kapalıyken de olmalı.
 * Flutter motoru arka planda askıya alındığı için bu seçim Dart'ta yapılamaz.
 */
object StreamSelector {

    /**
     * "Otomatik" kurulamadığında düşülen üst kalite sınırı. YouTube sık sık
     * 1440p/2160p sunar; telefonda bu fark edilmezken veri, pil ve kod
     * çözücüyü gereksiz zorlar (bazı cihazlarda 4K hiç çözülemez ve video
     * siyah kalır).
     */
    const val DEFAULT_MAX_HEIGHT = 1080

    /** Kalite menüsünde "Otomatik" seçiliyken gösterilen etiket. */
    const val AUTO_LABEL = "Otomatik"

    data class Selection(
        val videoUrl: String?,
        val audioUrl: String,
        val qualityLabel: String?,
        val isLive: Boolean
    )

    /**
     * [maxHeight] `null` ise kalite OTOMATİK: tüm çözünürlükler tek bir DASH
     * manifestine konur ve hangisinin oynatılacağına oynatıcı bant genişliğine
     * bakarak karar verir. Bir sayı verilirse o çözünürlük sabitlenir.
     */
    fun select(
        info: StreamInfo,
        audioOnly: Boolean,
        maxHeight: Int? = null
    ): Selection? {
        val isLive = info.streamType == StreamType.LIVE_STREAM ||
            info.streamType == StreamType.AUDIO_LIVE_STREAM

        // Canlı yayınlar ayrık progressive akış sunmaz; tek yol HLS manifestidir.
        val hlsUrl = info.hlsUrl
        if (isLive && !hlsUrl.isNullOrEmpty()) {
            return Selection(
                videoUrl = null,
                audioUrl = hlsUrl,
                qualityLabel = if (audioOnly) Lang.tr("Canlı • sadece ses", "Live • audio only") else Lang.tr("Canlı", "Live"),
                isLive = true
            )
        }

        val audio = info.audioStreams.maxByOrNull { it.averageBitrate }

        if (audioOnly) {
            val url = audio?.contentUrl()
            if (url != null) return Selection(null, url, Lang.tr("Sadece ses", "Audio only"), false)

            // Ayrık ses akışı yoksa SESSİZCE PES ETME.
            //
            // Eskiden burada `null` dönülüyordu; çağıran taraf
            // (`PlayerHolder.playQueueItem`) onu sessizce atlıyor ve kuyruk
            // olduğu yerde duruyordu — kullanıcı için "müzik bir sonraki
            // parçada durdu" demek, üstelik sebebi hiçbir yerde görünmüyor.
            //
            // Birleşik akış sesi de taşıyor; video parçası
            // `applyAudioOnlyTrackSelection` ile kapatılıyor, yani sesli mod
            // bozulmuyor ve oynatma devam ediyor.
            val combined = pickVideo(info.videoStreams, DEFAULT_MAX_HEIGHT)
            val combinedUrl = combined?.contentUrl()
            if (combinedUrl != null) {
                return Selection(null, combinedUrl, Lang.tr("Sadece ses", "Audio only"), false)
            }
            return null
        }

        // YouTube yüksek çözünürlükleri yalnızca "video-only" olarak sunar;
        // sesi ayrıca birleştiriyoruz.
        val audioUrl = audio?.contentUrl()
        if (audioUrl != null && info.videoOnlyStreams.isNotEmpty()) {
            if (maxHeight == null) {
                val manifest = DashManifestBuilder.videoOnlyDataUri(info)
                if (manifest != null) {
                    return Selection(manifest, audioUrl, AUTO_LABEL, false)
                }
            }
            // Manifest kurulamadıysa (ör. parça baytları gelmeyen OTF akışlar)
            // kullanıcıya hata göstermek yerine sessizce sabit çözünürlüğe
            // düşüyoruz.
            val chosen = pickVideo(info.videoOnlyStreams, maxHeight ?: DEFAULT_MAX_HEIGHT)
            val videoUrl = chosen?.contentUrl()
            if (videoUrl != null) {
                return Selection(videoUrl, audioUrl, chosen.resolution, false)
            }
        }

        // Ayrık ses yoksa: sesi zaten içeren birleşik akışı tek kaynak yap.
        if (info.videoStreams.isNotEmpty()) {
            val chosen = pickVideo(info.videoStreams, maxHeight ?: DEFAULT_MAX_HEIGHT)
            val url = chosen?.contentUrl()
            if (url != null) {
                return Selection(null, url, chosen.resolution, false)
            }
        }

        return audioUrl?.let { Selection(null, it, Lang.tr("Sadece ses", "Audio only"), false) }
    }

    private fun pickVideo(streams: List<VideoStream>, maxHeight: Int): VideoStream? {
        val sorted = streams.sortedByDescending { parseResolution(it.resolution) }
        return sorted.firstOrNull { parseResolution(it.resolution) <= maxHeight }
            ?: sorted.lastOrNull()
    }

    /** "1080p60" -> 1080 */
    fun parseResolution(resolution: String?): Int {
        if (resolution == null) return 0
        return Regex("(\\d+)").find(resolution)?.groupValues?.get(1)?.toIntOrNull() ?: 0
    }

    private fun VideoStream.contentUrl(): String? = content.takeIf { isUrl && it.isNotEmpty() }

    private fun AudioStream.contentUrl(): String? = content.takeIf { isUrl && it.isNotEmpty() }
}
