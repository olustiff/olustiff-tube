package com.olustiff.app.diag

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Oynatma sorunlarının KALICI günlüğü.
 *
 * Neden ayrı bir dosya: sistem günlüğü (logcat) küçük bir döngüsel alan ve
 * medya sistemi saniyede onlarca satır yazdığı için yalnızca son birkaç
 * dakikayı tutuyor. Arabada yaşanan bir takılmanın izi, telefon bilgisayara
 * takılana kadar çoktan silinmiş oluyordu.
 *
 * Dosya: `Android/data/com.olustiff.app/files/tanilama/olaylar.log`
 * (`adb pull` ile alınabiliyor, uygulamanın izni gerekmiyor). Yalnızca olay
 * türü, parça kimliği, süreler ve ağ türü yazılıyor; akış adresleri imza
 * taşıdığı için YAZILMIYOR.
 *
 * Boyut sınırlı: dosya [MAX_BYTES]'ı geçince bir öncekinin yerine geçiyor,
 * yani en fazla iki dosya; [MAX_AGE_MS]'den eski olan siliniyor.
 */
object Tanilama {

    private const val FILE_NAME = "olaylar.log"
    private const val OLD_FILE_NAME = "olaylar.1.log"
    private const val MAX_BYTES = 300 * 1024L
    private const val MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

    /** Diske yazma oynatma iş parçacığını HİÇ bekletmesin diye tek, ayrı bir iş parçacığı. */
    private val writer = Executors.newSingleThreadExecutor { r ->
        Thread(r, "olustiff-tanilama").apply { isDaemon = true }
    }

    private val timeFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.ROOT)

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var dir: File? = null

    /** Birden fazla giriş noktasından çağrılabilir; yalnızca ilki iş yapar. */
    fun init(context: Context) {
        if (dir != null) return
        val app = context.applicationContext
        appContext = app
        val target = app.getExternalFilesDir("tanilama") ?: File(app.filesDir, "tanilama")
        dir = target
        writer.execute {
            runCatching {
                target.mkdirs()
                val old = File(target, OLD_FILE_NAME)
                if (old.exists() && System.currentTimeMillis() - old.lastModified() > MAX_AGE_MS) {
                    old.delete()
                }
                val current = File(target, FILE_NAME)
                if (current.exists() && System.currentTimeMillis() - current.lastModified() > MAX_AGE_MS) {
                    current.delete()
                }
            }
        }
        val version = runCatching {
            app.packageManager.getPackageInfo(app.packageName, 0).versionName
        }.getOrNull()
        olay("Uygulama", "Süreç başladı (sürüm $version)")
    }

    /** Hem sistem günlüğüne hem kalıcı dosyaya yazar. */
    fun olay(tag: String, mesaj: String, hata: Throwable? = null) {
        if (hata != null) Log.w(tag, mesaj, hata) else Log.w(tag, mesaj)
        val target = dir ?: return
        val line = buildString {
            append(timeFormat.format(Date()))
            append(" [").append(networkType()).append("] ")
            append(tag).append(": ").append(mesaj)
            if (hata != null) {
                append(" | ").append(hata.javaClass.simpleName)
                hata.message?.let { append(": ").append(it.take(200)) }
            }
            append('\n')
        }
        writer.execute { append(target, line) }
    }

    private fun append(target: File, line: String) {
        runCatching {
            target.mkdirs()
            val file = File(target, FILE_NAME)
            if (file.length() > MAX_BYTES) {
                val old = File(target, OLD_FILE_NAME)
                old.delete()
                file.renameTo(old)
            }
            file.appendText(line)
        }
    }

    /** O anki ağ türü: takılmanın Wi-Fi'da mı mobilde mi olduğu çoğu zaman cevabın yarısı. */
    private fun networkType(): String {
        val context = appContext ?: return "?"
        return runCatching {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "AĞ YOK"
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "WIFI"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "MOBİL"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ETHERNET"
                else -> "DİĞER"
            }
        }.getOrDefault("?")
    }
}
