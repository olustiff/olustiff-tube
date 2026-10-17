package com.olustiff.app.download

import android.content.Context
import com.olustiff.app.diag.Tanilama
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.olustiff.app.extractor.ExtractionService
import com.olustiff.app.player.StreamSelector
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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

    /**
     * Android 9 ve öncesinde ortak Müzik klasörüne yazmak çalışma anı izni
     * ister; izni yalnızca MainActivity isteyebilir (izin diyaloğu bir
     * aktivite gerektirir), o yüzden istek dışarı bırakıldı.
     */
    var onRequestStoragePermission: (() -> Unit)? = null

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

            // MediaStore sorgusu IO'ya alınıyor.
            //
            // Eskiden doğrudan burada, yani ANA THREAD'de koşuyordu ve bu
            // liste uygulama açılışında isteniyor: MediaStore sağlayıcısının
            // soğuk açılışta ayağa kalkması + `LIKE` sorgusu + imleç döngüsü,
            // Flutter'ın ilk kareyi çizmek için ihtiyaç duyduğu thread'i
            // bekletiyordu. Aynı dosyadaki `downloadMp3` zaten bu kalıbı
            // kullanıyor; tutarsızlık buradaydı.
            "list" -> scope.launch {
                // Yakalanmayan istisna bu kapsamda uygulamayı düşürüyor;
                // klasör okunamazsa (izin, eski Android) Dart'a hata dönülür.
                try {
                    val items = withContext(Dispatchers.IO) { listDownloads() }
                    result.success(items)
                } catch (e: Exception) {
                    result.error("LIST_FAILED", e.message, null)
                }
            }

            "delete" -> {
                // Gelen değer artık dosya yolu değil, MediaStore kaydının
                // content:// adresi.
                val uri = call.argument<String>("path")
                result.success(
                    uri != null && MusicLibrary.delete(context, Uri.parse(uri))
                )
            }

            "openFolder" -> result.success(MusicLibrary.openFolder(context))

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

                // İzin yoksa indirmeye hiç başlamayalım: dakikalarca kodlayıp
                // sonunda yazamamak en kötü sonuç olurdu.
                if (MusicLibrary.needsPermission(context)) {
                    onRequestStoragePermission?.invoke()
                    result.error(
                        "NO_PERMISSION",
                        "Müzik klasörüne kaydetmek için depolama izni gerekiyor",
                        null
                    )
                    return@launch
                }

                val title = info.name ?: videoId
                // Dosya adında video kimliği yok: kullanıcı şarkıyı müzik
                // uygulamasında adıyla görmeli. Aynı ad ikinci kez gelirse
                // MusicLibrary üzerine yazmaz, "ad (1).mp3" diye çoğaltır.
                val displayName = sanitize(title).ifBlank { videoId } + ".mp3"

                val entry = withContext(Dispatchers.IO) {
                    MusicLibrary.save(
                        context = context,
                        displayName = displayName,
                        title = title,
                        artist = info.uploaderName
                    ) { output ->
                        Mp3Downloader.download(
                            audioUrl = selection.audioUrl,
                            output = output,
                            cacheDir = context.cacheDir,
                            bitrateKbps = bitrate
                        ) { progress ->
                            mainHandler.post {
                                progressSink?.success(
                                    mapOf("videoId" to videoId, "progress" to progress)
                                )
                            }
                        }
                    }
                }

                result.success(
                    mapOf(
                        "videoId" to videoId,
                        "title" to title,
                        "uploaderName" to info.uploaderName,
                        "durationSeconds" to info.duration,
                        // "path" artık dosya yolu değil content:// adresi.
                        "path" to entry.uri.toString(),
                        // Çakışma yüzünden değişmiş olabilir; gerçek ad bu.
                        "fileName" to entry.name,
                        "sizeBytes" to entry.sizeBytes,
                        "bitrate" to bitrate
                    )
                )
            } catch (e: Exception) {
                // Teşhis için tam yığın izi; kullanıcıya yalnızca mesaj gider.
                Tanilama.olay("AkisDownload", "MP3 indirme başarısız", e)
                result.error("DOWNLOAD_FAILED", e.message ?: "İndirme başarısız", null)
            }
        }
    }

    /**
     * Müzik kitaplığındaki MP3'ler. Uygulama verisi silinse de tutarlı kalır;
     * kullanıcı dosyayı telefonundan silmişse burada da görünmez.
     */
    private fun listDownloads(): List<Map<String, Any?>> =
        MusicLibrary.list(context).map {
            mapOf(
                "uri" to it.uri.toString(),
                "name" to it.name,
                "sizeBytes" to it.sizeBytes
            )
        }

    /** Dosya adında sorun çıkaracak karakterleri temizler. */
    private fun sanitize(name: String): String =
        name.replace(Regex("[^\\p{L}\\p{N} _-]"), "").trim().take(60)

    fun dispose() {
        scope.cancel()
        progressSink = null
    }

    companion object {
        const val CHANNEL = "olustiff/downloads"
        const val PROGRESS_CHANNEL = "olustiff/downloads_progress"
    }
}
