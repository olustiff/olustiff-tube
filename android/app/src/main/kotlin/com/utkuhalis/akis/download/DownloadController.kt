package com.utkuhalis.akis.download

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.utkuhalis.akis.extractor.ExtractionService
import com.utkuhalis.akis.player.StreamSelector
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Flutter'ın MP3 indirme isteklerini karşılar.
 *
 * Kaynak çözümlemesi native tarafta yapılır; böylece indirme oynatmayla aynı
 * seçim mantığını ([StreamSelector]) kullanır.
 */
class DownloadController(
    private val context: Context,
    channel: MethodChannel,
    progressChannel: EventChannel
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressSink: EventChannel.EventSink? = null

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "downloadMp3" -> downloadMp3(call, result)

            "list" -> result.success(listDownloads())

            "delete" -> {
                val path = call.argument<String>("path")
                result.success(path != null && File(path).delete())
            }

            else -> result.notImplemented()
        }
    }

    private fun downloadMp3(call: MethodCall, result: MethodChannel.Result) {
        val videoId = call.argument<String>("videoId")
        if (videoId.isNullOrBlank()) {
            result.error("BAD_ARGS", "videoId zorunlu", null)
            return
        }
        val bitrate = (call.argument<Number>("bitrate"))?.toInt() ?: 320

        scope.launch {
            try {
                val info = withContext(Dispatchers.IO) {
                    ExtractionService.streamInfo(videoId)
                }
                val selection = StreamSelector.select(info, audioOnly = true)
                if (selection == null) {
                    result.error("NO_STREAMS", "Ses kaynağı bulunamadı", null)
                    return@launch
                }
                if (selection.isLive) {
                    result.error("LIVE_STREAM", "Canlı yayınlar indirilemez", null)
                    return@launch
                }

                val title = info.name ?: videoId
                val file = File(
                    Mp3Downloader.downloadsDir(context),
                    "${sanitize(title)}-$videoId.mp3"
                )

                withContext(Dispatchers.IO) {
                    Mp3Downloader.download(
                        audioUrl = selection.audioUrl,
                        outputFile = file,
                        bitrateKbps = bitrate
                    ) { progress ->
                        mainHandler.post {
                            progressSink?.success(
                                mapOf("videoId" to videoId, "progress" to progress)
                            )
                        }
                    }
                }

                result.success(
                    mapOf(
                        "videoId" to videoId,
                        "title" to title,
                        "uploaderName" to info.uploaderName,
                        "durationSeconds" to info.duration,
                        "path" to file.absolutePath,
                        "sizeBytes" to file.length(),
                        "bitrate" to bitrate
                    )
                )
            } catch (e: Exception) {
                // Teşhis için tam yığın izi; kullanıcıya yalnızca mesaj gider.
                Log.e("AkisDownload", "MP3 indirme başarısız", e)
                result.error("DOWNLOAD_FAILED", e.message ?: "İndirme başarısız", null)
            }
        }
    }

    /** Diskteki MP3'ler. Uygulama verisi silinse de tutarlı kalır. */
    private fun listDownloads(): List<Map<String, Any?>> {
        return Mp3Downloader.downloadsDir(context).listFiles()
            ?.filter { it.isFile && it.extension == "mp3" }
            ?.sortedByDescending { it.lastModified() }
            ?.map {
                mapOf(
                    "path" to it.absolutePath,
                    "name" to it.name,
                    "sizeBytes" to it.length()
                )
            }
            ?: emptyList()
    }

    /** Dosya adında sorun çıkaracak karakterleri temizler. */
    private fun sanitize(name: String): String =
        name.replace(Regex("[^\\p{L}\\p{N} _-]"), "").trim().take(60)

    fun dispose() {
        scope.cancel()
        progressSink = null
    }

    companion object {
        const val CHANNEL = "akis/downloads"
        const val PROGRESS_CHANNEL = "akis/downloads_progress"
    }
}
