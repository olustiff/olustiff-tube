package com.olustiff.app.player

import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener

/**
 * YouTube akışını tek uzun istek yerine [chunkSize] baytlık PARÇALARLA
 * indirir; oynatıcıya yine tek, kesintisiz bir akış gibi görünür.
 *
 * TAKILMALARIN İKİNCİ SEBEBİ BU. YouTube uzun süren tek isteği oynatma
 * hızına kısıyor. Aynı videonun aynı görüntü akışı (480p, itag 135), ev
 * bağlantısından, 40 saniye:
 *
 *   tek istek (Range: bytes=0-)   5,8 MB  (~1,2 Mbps — videonun kendi hızı)
 *   1 MB'lık parçalar            32 MB    (~6,4 Mbps)
 *
 * Ses akışı tek istekle 60 sn HİÇ veri vermedi. Video modunda görüntü ve
 * ses birlikte bu kısıtlı hızla geliyordu; en küçük ağ dalgalanmasında
 * tampon bitiyor ve oynatıcı hata vermeden ~47 sn bekliyordu (günlükte 18
 * kez, hep video modunda, açılıştan birkaç saniye sonra). "Otomatik"
 * kalitede görüntü zaten parça parça (DASH) indirildiği için az etkileniyordu.
 *
 * Her parça ayrı bir istek; YouTube her birini tam hızla veriyor. Toplam
 * uzunluk adresteki `clen` değerinden biliniyor, böylece son parça doğru
 * yerde bitiyor.
 */
@UnstableApi
class ChunkedDataSource(
    private val upstream: DataSource,
    private val chunkSize: Long = DEFAULT_CHUNK_SIZE
) : DataSource {

    class Factory(
        private val upstream: DataSource.Factory,
        private val chunkSize: Long = DEFAULT_CHUNK_SIZE
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource =
            ChunkedDataSource(upstream.createDataSource(), chunkSize)
    }

    /** Parçalamadan olduğu gibi geçiriliyor mu (YouTube dışı ya da zaten kısa istek). */
    private var passthrough = false
    private var spec: DataSpec? = null

    /** Okunacak bir sonraki baytın dosyadaki konumu. */
    private var position = 0L

    /** Okumanın biteceği konum (hariç); bilinmiyorsa [C.LENGTH_UNSET]. */
    private var end = C.LENGTH_UNSET.toLong()

    /** Açık parçada kalan bayt; parça açık değilse 0. */
    private var chunkRemaining = 0L

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        passthrough = !shouldChunk(dataSpec, chunkSize)
        if (passthrough) return upstream.open(dataSpec)

        spec = dataSpec
        position = dataSpec.position
        val total = totalLength(dataSpec)
        val requestedEnd = if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
            dataSpec.position + dataSpec.length
        } else {
            C.LENGTH_UNSET.toLong()
        }
        end = when {
            total == C.LENGTH_UNSET.toLong() -> requestedEnd
            requestedEnd == C.LENGTH_UNSET.toLong() -> total
            else -> minOf(total, requestedEnd)
        }
        // Dosyanın sonundan açılış (ör. sona sarma): istenecek bayt yok.
        if (end != C.LENGTH_UNSET.toLong() && position >= end) return 0
        openChunk()
        return if (end == C.LENGTH_UNSET.toLong()) C.LENGTH_UNSET.toLong() else end - dataSpec.position
    }

    private fun openChunk() {
        val base = spec ?: return
        val length = if (end == C.LENGTH_UNSET.toLong()) chunkSize else minOf(chunkSize, end - position)
        val chunk = base.buildUpon()
            .setPosition(position)
            .setLength(length)
            .build()
        val opened = upstream.open(chunk)
        chunkRemaining = if (opened == C.LENGTH_UNSET.toLong()) length else minOf(opened, length)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (passthrough) return upstream.read(buffer, offset, length)
        if (length == 0) return 0
        if (end != C.LENGTH_UNSET.toLong() && position >= end) return C.RESULT_END_OF_INPUT

        if (chunkRemaining <= 0) {
            upstream.close()
            try {
                openChunk()
            } catch (e: HttpDataSource.InvalidResponseCodeException) {
                // Uzunluk bilinmiyorken bir önceki parça tam dosya sonunda
                // bittiyse sonraki parça "aralık dışı" (416) alır: bu da son.
                if (e.responseCode == 416 && end == C.LENGTH_UNSET.toLong()) {
                    return C.RESULT_END_OF_INPUT
                }
                throw e
            }
        }
        val read = upstream.read(buffer, offset, minOf(length.toLong(), chunkRemaining).toInt())
        if (read == C.RESULT_END_OF_INPUT) {
            // Parça istenenden KISA bitti: dosyanın sonu (uzunluk bilinmiyorken).
            chunkRemaining = 0
            return C.RESULT_END_OF_INPUT
        }
        position += read
        chunkRemaining -= read
        return read
    }

    override fun getUri() = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        spec = null
        chunkRemaining = 0
        upstream.close()
    }

    companion object {
        /**
         * 1 MB: ölçümde tam hızı veren boyut. Daha küçüğü her parçaya bir
         * istek gecikmesi ekler (zayıf mobilde ~100–300 ms); 480p video
         * 1 MB'ı ~8 saniyede oynatıyor, yani istek yükü önemsiz kalıyor.
         */
        const val DEFAULT_CHUNK_SIZE = 1L shl 20

        /** Yalnızca YouTube akış sunucuları ve parçadan uzun istekler bölünür. */
        fun shouldChunk(dataSpec: DataSpec, chunkSize: Long): Boolean {
            val uri = dataSpec.uri
            if (uri.scheme?.startsWith("http") != true) return false
            if (uri.host?.endsWith(".googlevideo.com") != true) return false
            return dataSpec.length == C.LENGTH_UNSET.toLong() || dataSpec.length > chunkSize
        }

        /** Dosyanın toplam uzunluğu: YouTube adresinde `clen` olarak yazılı. */
        private fun totalLength(dataSpec: DataSpec): Long =
            dataSpec.uri.getQueryParameter("clen")?.toLongOrNull() ?: C.LENGTH_UNSET.toLong()
    }
}
