package com.olustiff.app.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import com.olustiff.app.Lang
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream

/**
 * Uygulama içi güncelleme: APK'yı indirir ve Android'in kurulum ekranını açar.
 *
 * Kurulumu uygulama kendisi yapamaz; sistem paket yükleyicisini açmak
 * gerekir. Bunun için kullanıcının "bilinmeyen kaynaklardan kuruluma izin
 * ver" onayı istenir (sistem kendisi sorar).
 */
class UpdateController(
    private val context: Context,
    channel: MethodChannel,
    progressChannel: EventChannel
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val client = OkHttpClient.Builder().build()
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

        // Kurulumdan sonra APK önbellekte kalıyor ve boşuna ~55 MB yer
        // kaplıyordu. Kurulmuş ya da eskimiş indirmeler açılışta silinir.
        scope.launch(Dispatchers.IO) { cleanupDownloads() }
    }

    /** Kurulu sürümden yeni OLMAYAN indirmeleri siler. */
    private fun cleanupDownloads() {
        val dir = File(context.cacheDir, "updates")
        if (!dir.isDirectory) return
        val installed = installedVersion() ?: return

        dir.listFiles()?.forEach { file ->
            val version = file.name
                .removePrefix("olustiff-")
                .removeSuffix(".part")
                .removeSuffix(".apk")
            if (!isNewer(version, installed)) file.delete()
        }
    }

    /** Cihazın kullandığı mimari; sürüm dosyası buna göre seçilir. */
    private fun deviceAbi(): String = when {
        Build.SUPPORTED_ABIS.contains("arm64-v8a") -> "arm64"
        Build.SUPPORTED_ABIS.contains("armeabi-v7a") -> "arm32"
        Build.SUPPORTED_ABIS.contains("x86_64") -> "x64"
        else -> "universal"
    }

    private fun installedVersion(): String? = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    } catch (e: Exception) {
        null
    }

    /** "1.2.10" > "1.2.9" karşılaştırması; metin kıyası yanlış sonuç verir. */
    private fun isNewer(candidate: String, current: String): Boolean {
        fun parse(v: String) = v.split('.', '+', '-').map { it.toIntOrNull() ?: 0 }
        val a = parse(candidate)
        val b = parse(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "downloadAndInstall" -> {
                val url = call.argument<String>("url")
                val version = call.argument<String>("version") ?: "yeni"
                if (url.isNullOrBlank()) {
                    result.error("BAD_ARGS", "url zorunlu", null)
                    return
                }
                scope.launch {
                    try {
                        val expectedSize = (call.argument<Number>("sizeBytes"))?.toLong() ?: 0L
                        val apk = withContext(Dispatchers.IO) {
                            download(url, version, expectedSize)
                        }
                        install(apk)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("UPDATE_FAILED", e.message ?: Lang.tr("İndirme başarısız", "Download failed"), null)
                    }
                }
            }

            // Sürüm dosyaları işlemci mimarisine göre ayrı yayınlanıyor:
            // hepsini tek APK'da taşımak indirmeyi ~2,5 katına çıkarıyordu.
            "deviceAbi" -> result.success(deviceAbi())

            else -> result.notImplemented()
        }
    }

    private fun download(url: String, version: String, expectedSize: Long): File {
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        val target = File(dir, "olustiff-$version.apk")

        // Bu sürüm zaten inmiş: kullanıcı indirdiği halde kurmadıysa tekrar
        // 55 MB indirmesin. Boyut tutuyorsa dosya eksiksizdir.
        if (target.isFile && (expectedSize <= 0L || target.length() == expectedSize)) {
            mainHandler.post { progressSink?.success(mapOf("progress" to 1.0)) }
            return target
        }

        // Başka sürümlerin artıkları yer kaplamasın.
        dir.listFiles()?.forEach { if (it != target) it.delete() }

        // Yarım kalan indirme "tam" sanılmasın diye önce geçici ada yazılır.
        val part = File(dir, "olustiff-$version.apk.part")
        part.delete()
        val request = Request.Builder().url(url).build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException(Lang.tr("İndirilemedi (HTTP ${response.code})", "Download failed (HTTP ${response.code})"))
            }
            val body = response.body ?: throw IllegalStateException(Lang.tr("Boş yanıt", "Empty response"))
            val total = body.contentLength()
            var written = 0L

            body.byteStream().use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        written += read
                        if (total > 0) {
                            val progress = written.toDouble() / total
                            mainHandler.post {
                                progressSink?.success(mapOf("progress" to progress))
                            }
                        }
                    }
                }
            }
        }

        if (!part.renameTo(target)) {
            throw IllegalStateException(Lang.tr("İndirilen dosya taşınamadı", "Couldn't move the downloaded file"))
        }
        return target
    }

    /**
     * Sistem kurulum ekranını açar.
     *
     * APK'yı başka bir uygulamaya (paket yükleyici) verdiğimiz için doğrudan
     * dosya yolu değil, FileProvider üzerinden content:// adresi gerekiyor.
     */
    private fun install(apk: File) {
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            apk
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // Aktivite dışından başlatıldığı için yeni görev gerekir.
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    /** Cihaz "bilinmeyen kaynak" kurulumuna izin veriyor mu. */
    fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    fun dispose() {
        scope.cancel()
        progressSink = null
    }

    companion object {
        const val CHANNEL = "olustiff/update"
        const val PROGRESS_CHANNEL = "olustiff/update_progress"
    }
}
