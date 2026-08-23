package com.olustiff.app.player

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
     * Varsayılan üst kalite sınırı. YouTube sık sık 1440p/2160p sunar;
     * telefonda bu fark edilmezken veri, pil ve kod çözücüyü gereksiz zorlar
     * (bazı cihazlarda 4K hiç çözülemez ve video siyah kalır).
     */
    const val DEFAULT_MAX_HEIGHT = 1080

    data class Selection(
        val videoUrl: String?,
        val audioUrl: String,
        val qualityLabel: String?,
        val isLive: Boolean
    )

    fun select(
        info: StreamInfo,
        audioOnly: Boolean,
        maxHeight: Int = DEFAULT_MAX_HEIGHT
    ): Selection? {
        val isLive = info.streamType == StreamType.LIVE_STREAM ||
            info.streamType == StreamType.AUDIO_LIVE_STREAM

        // Canlı yayınlar ayrık progressive akış sunmaz; tek yol HLS manifestidir.
        val hlsUrl = info.hlsUrl
        if (isLive && !hlsUrl.isNullOrEmpty()) {
            return Selection(
                videoUrl = null,
                audioUrl = hlsUrl,
                qualityLabel = if (audioOnly) "Canlı • sadece ses" else "Canlı",
                isLive = true
            )
        }

        val audio = info.audioStreams.maxByOrNull { it.averageBitrate }

        if (audioOnly) {
            val url = audio?.contentUrl() ?: return null
            return Selection(null, url, "Sadece ses", false)
        }

        // YouTube yüksek çözünürlükleri yalnızca "video-only" olarak sunar;
        // sesi ayrıca birleştiriyoruz.
        val audioUrl = audio?.contentUrl()
        if (audioUrl != null && info.videoOnlyStreams.isNotEmpty()) {
            val chosen = pickVideo(info.videoOnlyStreams, maxHeight)
            val videoUrl = chosen?.contentUrl()
            if (videoUrl != null) {
                return Selection(videoUrl, audioUrl, chosen.resolution, false)
            }
        }

        // Ayrık ses yoksa: sesi zaten içeren birleşik akışı tek kaynak yap.
        if (info.videoStreams.isNotEmpty()) {
            val chosen = pickVideo(info.videoStreams, maxHeight)
            val url = chosen?.contentUrl()
            if (url != null) {
                return Selection(null, url, chosen.resolution, false)
            }
        }

        return audioUrl?.let { Selection(null, it, "Sadece ses", false) }
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
