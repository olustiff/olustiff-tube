package com.olustiff.app.download

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.naman14.androidlame.AndroidLame
import com.naman14.androidlame.LameBuilder
import com.olustiff.app.Lang
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * YouTube ses akışını gerçek bir MP3 dosyasına çevirir.
 *
 * Üç adım gerekiyor çünkü YouTube sesi M4A (AAC) veya WebM (Opus) olarak
 * verir ve Android'in kendi kodlayıcıları arasında MP3 YOKTUR:
 * 1. Akışı indir
 * 2. [MediaCodec] ile ham PCM'e çöz
 * 3. LAME ile MP3'e kodla
 */
object Mp3Downloader {

    private val client = OkHttpClient.Builder().build()

    /** Bkz. [fetch]: oynatıcıdaki parça boyutuyla aynı. */
    private const val CHUNK_SIZE = 1L shl 20

    /**
     * Sesi indirir ve MP3'e kodlayıp [output] akışına yazar.
     *
     * Hedef bir [File] değil [OutputStream]: MP3'ler artık ortak Müzik
     * klasörüne, MediaStore'un açtığı `content://` akışına yazılıyor
     * (bkz. [MusicLibrary]) — orada bir dosya yolumuz yok.
     *
     * [cacheDir] yalnızca ham ses akışını tutan geçici dosya içindir; iş
     * bitince (hata da olsa) silinir.
     *
     * [onProgress] 0..1 arası ilerleme bildirir; indirme uzun sürdüğü için
     * arayüzün kullanıcıya durum gösterebilmesi gerekiyor.
     */
    fun download(
        audioUrl: String,
        output: OutputStream,
        cacheDir: File,
        bitrateKbps: Int,
        onProgress: (Double) -> Unit
    ) {
        val temp = File.createTempFile("akis-audio", ".tmp", cacheDir)
        try {
            fetch(audioUrl, temp) { onProgress(it * 0.5) }
            encodeToMp3(temp, output, bitrateKbps) { onProgress(0.5 + it * 0.5) }
        } finally {
            temp.delete()
        }
    }

    /**
     * Ses akışını diske PARÇA PARÇA indirir.
     *
     * Tek uzun istek YouTube'da oynatma hızına kısılıyor (ölçüldü: ses
     * akışı tek istekle 60 sn hiç veri vermedi; görüntüde 1 MB'lık
     * parçalar 5,5 kat hızlı — bkz. PlayerHolder'daki ChunkedDataSource).
     * Bir şarkıyı indirmek şarkının süresi kadar sürüyordu.
     */
    private fun fetch(url: String, target: File, onProgress: (Double) -> Unit) {
        // Toplam boyut adreste yazılı; yoksa son parça kısa gelince bitiyor.
        val total = android.net.Uri.parse(url).getQueryParameter("clen")?.toLongOrNull() ?: -1L
        var written = 0L
        FileOutputStream(target).use { output ->
            val buffer = ByteArray(64 * 1024)
            while (total < 0 || written < total) {
                val last = written + CHUNK_SIZE - 1
                val request = Request.Builder()
                    .url(url)
                    // YouTube, tarayıcı görünmeyen isteklere içerik vermeyebiliyor.
                    .header(
                        "User-Agent",
                        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                            "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                    )
                    .header("Range", "bytes=$written-${if (total > 0) minOf(last, total - 1) else last}")
                    .build()
                var chunkBytes = 0L
                client.newCall(request).execute().use { response ->
                    // Uzunluk bilinmiyorken dosya sonunu aşan parça: bitti.
                    if (response.code == 416 && total < 0) return
                    if (!response.isSuccessful) {
                        throw IllegalStateException(Lang.tr("Ses indirilemedi (HTTP ${response.code})", "Couldn't download the audio (HTTP ${response.code})"))
                    }
                    val body = response.body ?: throw IllegalStateException(Lang.tr("Boş yanıt", "Empty response"))
                    body.byteStream().use { input ->
                        while (true) {
                            val read = input.read(buffer)
                            if (read == -1) break
                            output.write(buffer, 0, read)
                            written += read
                            chunkBytes += read
                            if (total > 0) onProgress(written.toDouble() / total)
                        }
                    }
                }
                // Parça istenenden kısa geldiyse dosyanın sonu.
                if (chunkBytes < CHUNK_SIZE) break
            }
        }
    }

    /** İndirilen sesi çözüp LAME ile MP3'e kodlar ve [target] akışına yazar. */
    private fun encodeToMp3(
        source: File,
        target: OutputStream,
        bitrateKbps: Int,
        onProgress: (Double) -> Unit
    ) {
        // Her kaynak HATA yolunda da bırakılıyor. Donanım kod çözücüleri
        // sınırlı; yarıda kalan birkaç indirmeden sonra serbest bırakılmayan
        // çözücüler yüzünden yeni indirmeler (ve video oynatma) açılamıyordu.
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var lame: AndroidLame? = null
        try {
            extractor.setDataSource(source.absolutePath)

            val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index)
                    .getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: throw IllegalStateException(Lang.tr("Ses parçası bulunamadı", "Audio track not found"))

            extractor.selectTrack(trackIndex)
            val inputFormat = extractor.getTrackFormat(trackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            val sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val durationUs = runCatching {
                inputFormat.getLong(MediaFormat.KEY_DURATION)
            }.getOrDefault(0L)

            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()

            val encoder = LameBuilder()
                .setInSampleRate(sampleRate)
                .setOutChannels(channels)
                .setOutSampleRate(sampleRate)
                .setOutBitrate(bitrateKbps)
                .setQuality(2) // 0 en iyi, 9 en hızlı; 2 kalite/hız dengesi
                .build()
            lame = encoder

            // Akışı KAPATMIYORUZ, yalnızca boşaltıyoruz: akışın sahibi çağıran
            // taraf (MediaStore kaydı) ve kapatma sırasını o yönetiyor.
            val output = BufferedOutputStream(target)
            writeMp3(extractor, decoder, encoder, output, channels, durationUs, onProgress)
            output.flush()
        } finally {
            codec?.let { runCatching { it.stop() }; it.release() }
            extractor.release()
            lame?.close()
        }
    }

    private fun writeMp3(
        extractor: MediaExtractor,
        codec: MediaCodec,
        lame: AndroidLame,
        output: BufferedOutputStream,
        channels: Int,
        durationUs: Long,
        onProgress: (Double) -> Unit
    ) {
        val bufferInfo = MediaCodec.BufferInfo()
        // LAME'in önerdiği tampon boyutu: örnek sayısı * 1.25 + 7200
        val mp3Buffer = ByteArray(8192 + 7200)
        var inputDone = false
        var lastReportedProgress = 0.0

        while (true) {
            if (!inputDone) {
                val inputIndex = codec.dequeueInputBuffer(10_000)
                if (inputIndex >= 0) {
                    val inputBuffer = codec.getInputBuffer(inputIndex)!!
                    val sampleSize = extractor.readSampleData(inputBuffer, 0)
                    if (sampleSize < 0) {
                        codec.queueInputBuffer(
                            inputIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM
                        )
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(
                            inputIndex, 0, sampleSize, extractor.sampleTime, 0
                        )
                        if (durationUs > 0) {
                            val progress =
                                extractor.sampleTime.toDouble() / durationUs
                            // Her karede bildirim göndermek gereksiz yük.
                            if (progress - lastReportedProgress > 0.02) {
                                lastReportedProgress = progress
                                onProgress(progress.coerceIn(0.0, 1.0))
                            }
                        }
                        extractor.advance()
                    }
                }
            }

            val outputIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
            if (outputIndex >= 0) {
                if (bufferInfo.size > 0) {
                    val outputBuffer = codec.getOutputBuffer(outputIndex)!!
                    outputBuffer.position(bufferInfo.offset)
                    outputBuffer.limit(bufferInfo.offset + bufferInfo.size)

                    val encoded = encodePcm(outputBuffer, bufferInfo.size, channels, lame, mp3Buffer)
                    if (encoded > 0) output.write(mp3Buffer, 0, encoded)
                }
                codec.releaseOutputBuffer(outputIndex, false)

                if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            } else if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER && inputDone) {
                // Girdi bitti ve çıktı da gelmiyorsa döngüde takılmayalım.
                continue
            }
        }

        val flushed = lame.flush(mp3Buffer)
        if (flushed > 0) output.write(mp3Buffer, 0, flushed)
        onProgress(1.0)
    }

    /** Çözülmüş PCM'i LAME'e verir; mono ve stereo ayrı ele alınır. */
    private fun encodePcm(
        buffer: ByteBuffer,
        size: Int,
        channels: Int,
        lame: AndroidLame,
        mp3Buffer: ByteArray
    ): Int {
        val shorts = buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val sampleCount = size / 2
        val pcm = ShortArray(sampleCount)
        shorts.get(pcm, 0, sampleCount)

        return if (channels == 1) {
            lame.encode(pcm, pcm, sampleCount, mp3Buffer)
        } else {
            // Stereo veri araya geçmiş (L R L R…) geliyor; LAME ayrı kanallar ister.
            val perChannel = sampleCount / 2
            val left = ShortArray(perChannel)
            val right = ShortArray(perChannel)
            for (i in 0 until perChannel) {
                left[i] = pcm[i * 2]
                right[i] = pcm[i * 2 + 1]
            }
            lame.encode(left, right, perChannel, mp3Buffer)
        }
    }
}
