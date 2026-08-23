package com.olustiff.app.download

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.naman14.androidlame.AndroidLame
import com.naman14.androidlame.LameBuilder
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
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

    /** İndirilen dosyaların tutulduğu klasör (uygulamaya özel, izin gerekmez). */
    fun downloadsDir(context: android.content.Context): File =
        File(context.getExternalFilesDir(null), "downloads").apply { mkdirs() }

    private val client = OkHttpClient.Builder().build()

    /**
     * [onProgress] 0..1 arası ilerleme bildirir; indirme uzun sürdüğü için
     * arayüzün kullanıcıya durum gösterebilmesi gerekiyor.
     */
    fun download(
        audioUrl: String,
        outputFile: File,
        bitrateKbps: Int,
        onProgress: (Double) -> Unit
    ): File {
        val temp = File.createTempFile("akis-audio", ".tmp", outputFile.parentFile)
        try {
            fetch(audioUrl, temp) { onProgress(it * 0.5) }
            encodeToMp3(temp, outputFile, bitrateKbps) { onProgress(0.5 + it * 0.5) }
            return outputFile
        } finally {
            temp.delete()
        }
    }

    /** Ses akışını diske indirir. */
    private fun fetch(url: String, target: File, onProgress: (Double) -> Unit) {
        val request = Request.Builder()
            .url(url)
            // YouTube, tarayıcı görünmeyen isteklere içerik vermeyebiliyor.
            .header(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            )
            .build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("Ses indirilemedi (HTTP ${response.code})")
            }
            val body = response.body ?: throw IllegalStateException("Boş yanıt")
            val total = body.contentLength()
            var written = 0L

            body.byteStream().use { input ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        written += read
                        if (total > 0) onProgress(written.toDouble() / total)
                    }
                }
            }
        }
    }

    /** İndirilen sesi çözüp LAME ile MP3'e kodlar. */
    private fun encodeToMp3(
        source: File,
        target: File,
        bitrateKbps: Int,
        onProgress: (Double) -> Unit
    ) {
        val extractor = MediaExtractor()
        extractor.setDataSource(source.absolutePath)

        val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
            extractor.getTrackFormat(index)
                .getString(MediaFormat.KEY_MIME)
                ?.startsWith("audio/") == true
        } ?: throw IllegalStateException("Ses parçası bulunamadı")

        extractor.selectTrack(trackIndex)
        val inputFormat = extractor.getTrackFormat(trackIndex)
        val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
        val sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val durationUs = runCatching {
            inputFormat.getLong(MediaFormat.KEY_DURATION)
        }.getOrDefault(0L)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(inputFormat, null, null, 0)
        codec.start()

        val lame = LameBuilder()
            .setInSampleRate(sampleRate)
            .setOutChannels(channels)
            .setOutSampleRate(sampleRate)
            .setOutBitrate(bitrateKbps)
            .setQuality(2) // 0 en iyi, 9 en hızlı; 2 kalite/hız dengesi
            .build()

        BufferedOutputStream(FileOutputStream(target)).use { output ->
            writeMp3(extractor, codec, lame, output, channels, durationUs, onProgress)
        }

        codec.stop()
        codec.release()
        extractor.release()
        lame.close()
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
