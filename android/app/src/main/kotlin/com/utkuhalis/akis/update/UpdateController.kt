package com.utkuhalis.akis.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
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
                        val apk = withContext(Dispatchers.IO) { download(url, version) }
                        install(apk)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("UPDATE_FAILED", e.message ?: "İndirme başarısız", null)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun download(url: String, version: String): File {
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        // Eski indirmeler birikmesin.
        dir.listFiles()?.forEach { it.delete() }

        val target = File(dir, "olustiff-$version.apk")
        val request = Request.Builder().url(url).build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("İndirilemedi (HTTP ${response.code})")
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
        const val CHANNEL = "akis/update"
        const val PROGRESS_CHANNEL = "akis/update_progress"
    }
}
