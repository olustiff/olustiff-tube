package com.olustiff.app.player

import android.util.Base64
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.VideoStream

/**
 * "Otomatik" kalite için uyarlanabilir (adaptive) bir DASH manifesti üretir.
 *
 * Neden kendimiz üretiyoruz: YouTube normal videolar için hazır bir DASH
 * manifesti VERMEZ ([StreamInfo.getDashMpdUrl] yalnızca canlı/DVR yayınlarda
 * dolu gelir). Elimizdeki tek şey her çözünürlük için ayrı bir progressive
 * adres; oynatıcıya bunlardan birini verdiğimizde bant genişliği düştüğünde
 * kalite düşürecek bir seçenek kalmıyor ve video takılıyor.
 *
 * Çözüm: tüm çözünürlükleri TEK bir manifestte "Representation" olarak
 * toplamak. Bunun için gereken her şey (parça baytları, kodek, bant genişliği)
 * zaten çıkarıcıdan geliyor; oynatıcı da böylece indirme hızına göre
 * çözünürlükler arasında kendiliğinden geçiş yapabiliyor.
 *
 * Manifest bir adres olarak taşınıyor (`data:` URI): oynatma isteği Dart'tan
 * yalnızca "video adresi + ses adresi" olarak geçiyor ve bu yol değiştirilmeden
 * manifest de aynı alandan iletilebiliyor.
 */
object DashManifestBuilder {

    const val DATA_URI_PREFIX = "data:application/dash+xml;base64,"

    fun isManifest(url: String?): Boolean = url != null && url.startsWith(DATA_URI_PREFIX)

    fun decode(url: String): ByteArray =
        Base64.decode(url.removePrefix(DATA_URI_PREFIX), Base64.DEFAULT)

    private fun dataUri(manifest: String): String =
        DATA_URI_PREFIX + Base64.encodeToString(
            manifest.toByteArray(Charsets.UTF_8),
            // NO_WRAP: satır sonu karakterleri adresi bozardı.
            Base64.NO_WRAP
        )

    /**
     * Videonun tüm çözünürlüklerini içeren manifestin `data:` adresi.
     *
     * Kurulamıyorsa null döner — çağıran taraf eski davranışa (tek bir
     * progressive adres) düşmelidir. Kurulamama nedenleri gerçek: canlı
     * yayınlar, YouTube'un parça baytlarını vermediği OTF akışlar, süresi
     * bilinmeyen içerikler.
     */
    fun videoOnlyDataUri(info: StreamInfo): String? {
        val manifest = buildVideoOnly(info.videoOnlyStreams, info.duration) ?: return null
        return dataUri(manifest)
    }

    /** Test/okuma kolaylığı için ham XML. */
    fun buildVideoOnly(streams: List<VideoStream>, durationSeconds: Long): String? {
        if (durationSeconds <= 0) return null

        val representations = streams.mapNotNull { it.toRepresentation() }
        // Tek temsilci varsa uyarlanacak bir şey yok; manifestin ek yükünü
        // taşımak yerine eski (progressive) yola düşmek daha doğru.
        if (representations.size < 2) return null

        // Kodekler arası geçiş her cihazda desteklenmediği için her kodek
        // ailesi kendi AdaptationSet'ine giriyor; oynatıcı bir aile seçip
        // yalnızca onun içinde çözünürlük değiştiriyor.
        val groups = representations
            .groupBy { it.mimeType to it.codec.substringBefore('.') }
            .values
            .filter { it.size >= 2 }
            .sortedByDescending { it.size }
        if (groups.isEmpty()) return null

        return buildString {
            append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
            append("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" ")
            append("profiles=\"urn:mpeg:dash:profile:isoff-on-demand:2011\" ")
            append("type=\"static\" minBufferTime=\"PT1.5S\" ")
            append("mediaPresentationDuration=\"PT${durationSeconds}S\">")
            append("<Period duration=\"PT${durationSeconds}S\">")
            groups.forEachIndexed { index, group ->
                append("<AdaptationSet id=\"$index\" mimeType=\"${group.first().mimeType}\" ")
                append("contentType=\"video\" subsegmentAlignment=\"true\" startWithSAP=\"1\">")
                // Düşükten yükseğe: oynatıcı ilk parçayı en düşükten çekip
                // ölçümüne göre yükseliyor, böylece açılış takılmıyor.
                group.sortedBy { it.bandwidth }.forEach { append(it.toXml()) }
                append("</AdaptationSet>")
            }
            append("</Period></MPD>")
        }
    }

    private data class Representation(
        val id: Int,
        val mimeType: String,
        val codec: String,
        val bandwidth: Int,
        val width: Int,
        val height: Int,
        val fps: Int,
        val url: String,
        val initStart: Int,
        val initEnd: Int,
        val indexStart: Int,
        val indexEnd: Int
    ) {
        fun toXml(): String = buildString {
            append("<Representation id=\"$id\" codecs=\"${escape(codec)}\" ")
            append("bandwidth=\"$bandwidth\" width=\"$width\" height=\"$height\"")
            if (fps > 0) append(" frameRate=\"$fps\"")
            append(">")
            append("<BaseURL>${escape(url)}</BaseURL>")
            append("<SegmentBase indexRange=\"$indexStart-$indexEnd\">")
            append("<Initialization range=\"$initStart-$initEnd\"/>")
            append("</SegmentBase>")
            append("</Representation>")
        }
    }

    /**
     * Parça baytları (init/index aralıkları) olmayan akış manifeste giremez:
     * oynatıcı o akışın parça dizinini bulamaz. YouTube bunları OTF
     * akışlarda vermez, orada -1 gelir.
     */
    private fun VideoStream.toRepresentation(): Representation? {
        val url = content.takeIf { isUrl && it.isNotEmpty() } ?: return null
        val codec = codec?.takeIf { it.isNotBlank() } ?: return null
        val mimeType = format?.mimeType?.takeIf { it.isNotBlank() } ?: return null
        if (initEnd <= 0 || indexEnd <= 0) return null
        if (initStart < 0 || indexStart < 0) return null
        if (bitrate <= 0 || width <= 0 || height <= 0) return null
        return Representation(
            id = itag,
            mimeType = mimeType,
            codec = codec,
            bandwidth = bitrate,
            width = width,
            height = height,
            fps = fps,
            url = url,
            initStart = initStart,
            initEnd = initEnd,
            indexStart = indexStart,
            indexEnd = indexEnd
        )
    }

    /** YouTube adresleri `&` içeriyor; kaçırılmazsa XML bozulur. */
    private fun escape(value: String): String = value
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
}
