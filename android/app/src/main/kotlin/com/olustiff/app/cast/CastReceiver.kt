package com.olustiff.app.cast

import android.content.Context
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import kotlin.math.roundToInt

/**
 * Televizyon tarafındaki yayın (cast) alıcısı.
 *
 * İki parça:
 * 1. UDP dinleyicisi — telefonun ağa saldığı "orada kimse var mı" paketine
 *    cihaz adıyla cevap verir.
 * 2. Küçük bir HTTP sunucusu — "şu videoyu oynat" ve uzaktan kumanda
 *    komutlarını alır.
 *
 * Neden native: gelen istek uygulamayı ÖNE GETİRMEK zorunda ve `startActivity`
 * yalnızca native taraftan çağrılabiliyor. Ayrıca Android, yayın (broadcast)
 * paketlerini `MulticastLock` alınmadan uygulamalara vermiyor — o kilit de
 * yalnızca burada alınabilir.
 *
 * Sunucu, uygulamanın SÜRECİ yaşadığı sürece açık. Televizyonda uygulama hiç
 * açılmadıysa (ya da sistem süreci öldürdüyse) cihaz keşifte görünmez;
 * telefon bu durumda kullanıcıya ne yapması gerektiğini söylüyor.
 */
class CastReceiver(
    private val context: Context,
    private val channel: MethodChannel,
    /** Uygulamayı öne getirir; yayın isteği geldiğinde çağrılır. */
    private val bringToFront: () -> Unit
) {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var running = false

    private var udpSocket: DatagramSocket? = null
    private var serverSocket: ServerSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /**
     * Televizyonda çalanın son bilinen hâli (JSON).
     *
     * HTTP isteği kendi thread'inde geliyor ve ExoPlayer yalnızca ana
     * thread'den okunabiliyor; bu yüzden durum Flutter tarafından düzenli
     * olarak buraya YAZILIYOR, istek anında okunuyor.
     */
    @Volatile
    private var playbackState: Map<*, *>? = null

    /**
     * Televizyonun medya sesini yöneten servis.
     *
     * Neden ExoPlayer'ın kendi `volume` değeri DEĞİL de cihazın medya sesi:
     * - Kullanıcının "televizyonun sesi" dediği şey bu; kumandayla
     *   değiştirdiğiyle aynı düğme olmalı.
     * - Cihaz sesini değiştirmek televizyonun kendi ses göstergesini de
     *   açıyor: karşıdan bakan kullanıcı ne olduğunu görüyor.
     * - Ses yükseltme (LoudnessBoost) ExoPlayer'ın ses oturumuna uygulanan
     *   AYRI bir kazanç katmanı. Seviye ile kazanç birbirine karışmasın diye
     *   seviyeyi player'ın dışında tutuyoruz; biri diğerini sıfırlamıyor.
     */
    private val audio: AudioManager? by lazy {
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }

    init {
        channel.setMethodCallHandler { call, result -> handleMethod(call, result) }
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startReceiver" -> {
                start()
                result.success(running)
            }

            "publishState" -> {
                playbackState = call.arguments as? Map<*, *>
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- yaşam döngüsü

    @Synchronized
    fun start() {
        if (running) return
        running = true

        // Wi-Fi sürücüsü, kilit alınmadan gelen yayın/çok noktaya yayın
        // paketlerini uygulamaya HİÇ vermiyor: keşif bu kilit olmadan sessizce
        // çalışmaz.
        runCatching {
            val wifi = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("olustiff-cast")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }.onFailure { Log.w(TAG, "Multicast kilidi alınamadı", it) }

        startThread("olustiff-cast-udp", ::runDiscoveryLoop)
        startThread("olustiff-cast-http", ::runHttpLoop)
    }

    @Synchronized
    fun stop() {
        running = false
        // Soketleri kapatmak, `accept`/`receive` üzerinde bekleyen thread'leri
        // istisnayla uyandırır: döngüler böyle sonlanıyor.
        runCatching { udpSocket?.close() }
        runCatching { serverSocket?.close() }
        runCatching { multicastLock?.takeIf { it.isHeld }?.release() }
        udpSocket = null
        serverSocket = null
        multicastLock = null
    }

    private fun startThread(name: String, body: () -> Unit) {
        Thread({
            try {
                body()
            } catch (e: Throwable) {
                // Alıcı çökse bile televizyon uygulaması normal çalışmaya
                // devam etmeli; yayın yalnızca bir ek özellik.
                Log.w(TAG, "$name durdu", e)
            }
        }, name).apply { isDaemon = true }.start()
    }

    // ------------------------------------------------------------------- keşif

    private fun runDiscoveryLoop() {
        val socket = DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            bind(InetSocketAddress(DISCOVERY_PORT))
        }
        udpSocket = socket

        val buffer = ByteArray(1024)
        while (running) {
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                socket.receive(packet)
            } catch (e: Exception) {
                if (running) Log.w(TAG, "Keşif paketi alınamadı", e)
                return
            }
            val raw = String(packet.data, 0, packet.length, StandardCharsets.UTF_8)
            if (!isDiscoveryProbe(raw)) continue

            // Cevap tek noktaya (unicast) gidiyor: soruyu soran telefon,
            // paketi kendi geçici portundan yolluyor.
            val reply = announcement().toByteArray(StandardCharsets.UTF_8)
            runCatching {
                socket.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
            }.onFailure { Log.w(TAG, "Keşif cevabı gönderilemedi", it) }
        }
    }

    private fun isDiscoveryProbe(raw: String): Boolean = runCatching {
        val json = JSONObject(raw)
        json.optString("m") == MAGIC && json.optString("t") == "discover"
    }.getOrDefault(false)

    private fun announcement(): String = JSONObject().apply {
        put("m", MAGIC)
        put("t", "device")
        put("v", PROTOCOL_VERSION)
        put("id", deviceId())
        put("name", deviceName())
        put("port", CONTROL_PORT)
        put("app", appVersion())
    }.toString()

    /**
     * Cihazı ağ adresinden bağımsız tanımlar.
     *
     * ANDROID_ID uygulama+cihaz başına sabit: IP değişse de telefon "aynı
     * televizyon" olduğunu anlar. Cihazı ağ dışında tanımlamaya yaramadığı
     * için gizlilik açısından da uygun.
     */
    private fun deviceId(): String = runCatching {
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: "olustiff-tv"

    /** Kullanıcının televizyona verdiği ad; yoksa modeli. */
    private fun deviceName(): String {
        val configured = runCatching {
            Settings.Global.getString(context.contentResolver, "device_name")
        }.getOrNull()
        return configured?.takeIf { it.isNotBlank() }
            ?: android.os.Build.MODEL
            ?: "Televizyon"
    }

    private fun appVersion(): String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull() ?: ""

    // -------------------------------------------------------------------- komut

    private fun runHttpLoop() {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(CONTROL_PORT))
        serverSocket = server

        while (running) {
            val client = try {
                server.accept()
            } catch (e: Exception) {
                if (running) Log.w(TAG, "Bağlantı kabul edilemedi", e)
                return
            }
            // İstekler çok kısa ve seyrek; sırayla işlemek yeterli. Yine de
            // bir istemcinin yarım bıraktığı bağlantı sunucuyu kilitlemesin
            // diye zaman aşımı var.
            runCatching {
                client.soTimeout = SOCKET_TIMEOUT_MS
                handleConnection(client)
            }.onFailure { Log.w(TAG, "İstek işlenemedi", it) }
            runCatching { client.close() }
        }
    }

    private fun handleConnection(client: Socket) {
        val request = readRequest(client.getInputStream())
        if (request == null) {
            respond(client, 400, """{"ok":false,"error":"bad_request"}""")
            return
        }

        when {
            request.method == "GET" && request.path == "/ping" ->
                respond(client, 200, announcement())

            request.method == "GET" && request.path == "/state" ->
                respond(client, 200, """{"ok":true,"state":${encodeState()}}""")

            request.method == "POST" && request.path == "/cast" ->
                handleCast(client, request.body)

            request.method == "POST" && request.path == "/command" ->
                handleCommand(client, request.body)

            else -> respond(client, 404, """{"ok":false,"error":"not_found"}""")
        }
    }

    private fun handleCast(client: Socket, body: String) {
        val json = runCatching { JSONObject(body) }.getOrNull()
        val videoId = json?.optString("videoId").orEmpty()
        if (videoId.isBlank()) {
            respond(client, 400, """{"ok":false,"error":"missing_video"}""")
            return
        }

        val payload = mapOf(
            "videoId" to videoId,
            "title" to json?.optString("title").orEmpty(),
            "positionMs" to (json?.optLong("positionMs") ?: 0L)
        )
        mainHandler.post {
            // Önce öne getir: televizyon başka bir uygulamadaysa video
            // arkada açılıp kimse görmezdi.
            runCatching { bringToFront() }
                .onFailure { Log.w(TAG, "Uygulama öne getirilemedi", it) }
            channel.invokeMethod("castPlay", payload)
        }
        // Cevabı Flutter'ı BEKLEMEDEN veriyoruz: video çözümlemesi saniyeler
        // sürebiliyor, telefon o kadar beklerse zaman aşımına düşer.
        respond(client, 200, """{"ok":true}""")
    }

    private fun handleCommand(client: Socket, body: String) {
        val json = runCatching { JSONObject(body) }.getOrNull()
        val action = json?.optString("action").orEmpty()
        if (action !in COMMANDS) {
            respond(client, 400, """{"ok":false,"error":"unknown_command"}""")
            return
        }

        // Ses komutları Flutter'a UĞRAMADAN burada işleniyor: ses seviyesi
        // AudioManager'da yaşıyor, oynatıcıda değil. Ayrıca ses tuşuna
        // basıldığında gecikme en çok burada göze batar.
        if (action in VOLUME_COMMANDS) {
            val applied = applyVolume(action, json)
            respond(
                client,
                if (applied) 200 else 500,
                if (applied) """{"ok":true}"""
                else """{"ok":false,"error":"volume_unavailable"}"""
            )
            return
        }

        val payload = mapOf(
            "action" to action,
            "positionMs" to (json?.optLong("positionMs") ?: 0L)
        )
        mainHandler.post { channel.invokeMethod("castCommand", payload) }
        respond(client, 200, """{"ok":true}""")
    }

    /**
     * Ses komutunu uygular.
     *
     * FLAG_SHOW_UI: televizyonun kendi ses göstergesi açılsın — kullanıcı
     * telefondan bastığında ekranda karşılığını görüyor.
     */
    private fun applyVolume(action: String, json: JSONObject?): Boolean {
        val manager = audio ?: return false
        val max = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return false

        return runCatching {
            when (action) {
                "volume" -> {
                    val level = json?.optDouble("volume", 0.0) ?: 0.0
                    val index = (level.coerceIn(0.0, 1.0) * max).roundToInt()
                    // Sesi elle ayarlamak sessizliği de bozar: kullanıcı
                    // kaydırıcıyı çektiğinde ses gelmesini bekler.
                    if (manager.isStreamMute(AudioManager.STREAM_MUSIC)) {
                        manager.adjustStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.ADJUST_UNMUTE,
                            0
                        )
                    }
                    manager.setStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        index,
                        AudioManager.FLAG_SHOW_UI
                    )
                }

                "volumeUp", "volumeDown" -> {
                    // Cihazın kendi kademesi (0..100 aralığında 1 birim) çok
                    // küçük; duyulur bir fark için sabit oranlı adım
                    // kullanılıyor.
                    val step = (max * VOLUME_STEP).roundToInt().coerceAtLeast(1)
                    val current = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
                    val delta = if (action == "volumeUp") step else -step
                    if (action == "volumeUp" &&
                        manager.isStreamMute(AudioManager.STREAM_MUSIC)
                    ) {
                        manager.adjustStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            AudioManager.ADJUST_UNMUTE,
                            0
                        )
                    }
                    manager.setStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        (current + delta).coerceIn(0, max),
                        AudioManager.FLAG_SHOW_UI
                    )
                }

                "mute" -> manager.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    AudioManager.ADJUST_TOGGLE_MUTE,
                    AudioManager.FLAG_SHOW_UI
                )

                else -> return false
            }
            true
        }.getOrElse {
            // "Rahatsız etmeyin" açıkken ses değiştirmek SecurityException
            // fırlatabiliyor; telefona dürüstçe "olmadı" diyoruz.
            Log.w(TAG, "Ses ayarlanamadı", it)
            false
        }
    }

    // --------------------------------------------------------------- HTTP altyapı

    private class Request(val method: String, val path: String, val body: String)

    /**
     * İsteği ham bayt düzeyinde okur.
     *
     * `BufferedReader` KULLANILMIYOR: Content-Length BAYT sayısını verir,
     * okuyucu ise karakter okur — Türkçe karakterli bir başlıkta gövde eksik
     * okunur ve JSON bozulurdu.
     */
    private fun readRequest(input: InputStream): Request? {
        val header = StringBuilder()
        var window = 0
        while (true) {
            val byte = input.read()
            if (byte < 0) return null
            header.append(byte.toChar())
            window = (window shl 8) or byte
            if (window == HEADER_END) break
            if (header.length > MAX_HEADER_BYTES) return null
        }

        val lines = header.toString().split("\r\n")
        val requestLine = lines.firstOrNull()?.split(" ") ?: return null
        if (requestLine.size < 2) return null

        val length = lines.asSequence()
            .drop(1)
            .firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
            ?.substringAfter(':')
            ?.trim()
            ?.toIntOrNull()
            ?: 0

        val body = if (length in 1..MAX_BODY_BYTES) {
            val bytes = ByteArray(length)
            var read = 0
            while (read < length) {
                val n = input.read(bytes, read, length - read)
                if (n < 0) break
                read += n
            }
            String(bytes, 0, read, StandardCharsets.UTF_8)
        } else {
            ""
        }

        return Request(requestLine[0], requestLine[1].substringBefore('?'), body)
    }

    private fun respond(client: Socket, status: Int, body: String) {
        val bytes = body.toByteArray(StandardCharsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 ").append(status).append(' ')
            append(if (status == 200) "OK" else "Error").append("\r\n")
            append("Content-Type: application/json; charset=utf-8\r\n")
            append("Content-Length: ").append(bytes.size).append("\r\n")
            // Bağlantıyı açık tutmuyoruz: istekler seyrek ve tek atımlık.
            append("Connection: close\r\n\r\n")
        }
        client.getOutputStream().apply {
            write(head.toByteArray(StandardCharsets.US_ASCII))
            write(bytes)
            flush()
        }
    }

    /**
     * Telefona bildirilecek durum.
     *
     * Oynatma bilgisi Flutter'dan geliyor, ses ise HER İSTEKTE cihazdan
     * okunuyor: kullanıcı televizyonun kendi kumandasıyla sesi değiştirdiğinde
     * telefondaki kaydırıcı da doğru yeri göstersin.
     */
    private fun encodeState(): String {
        val map = playbackState ?: return "null"
        val manager = audio
        val max = manager?.getStreamMaxVolume(AudioManager.STREAM_MUSIC) ?: 0
        return JSONObject().apply {
            put("videoId", map["videoId"] ?: JSONObject.NULL)
            put("title", map["title"] ?: JSONObject.NULL)
            put("positionMs", map["positionMs"] ?: 0)
            put("durationMs", map["durationMs"] ?: JSONObject.NULL)
            put("isPlaying", map["isPlaying"] ?: false)
            if (manager != null && max > 0) {
                put(
                    "volume",
                    manager.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
                )
                put("muted", manager.isStreamMute(AudioManager.STREAM_MUSIC))
            } else {
                // null = "bilmiyoruz"; telefon kaydırıcıyı hiç göstermiyor.
                put("volume", JSONObject.NULL)
                put("muted", false)
            }
        }.toString()
    }

    companion object {
        const val CHANNEL = "olustiff/cast"

        /** Protokol sabitleri Dart tarafındaki `cast_protocol.dart` ile aynı olmalı. */
        private const val MAGIC = "olustiff-cast"
        private const val PROTOCOL_VERSION = 1
        private const val DISCOVERY_PORT = 45632
        private const val CONTROL_PORT = 45633

        private val VOLUME_COMMANDS =
            setOf("volume", "volumeUp", "volumeDown", "mute")

        private val COMMANDS =
            setOf("resume", "pause", "seek", "next", "previous", "stop") +
                VOLUME_COMMANDS

        /** Bir ses düğmesi basışının oynattığı oran. */
        private const val VOLUME_STEP = 0.05

        private const val HEADER_END = 0x0D0A0D0A
        private const val MAX_HEADER_BYTES = 8 * 1024
        private const val MAX_BODY_BYTES = 64 * 1024
        private const val SOCKET_TIMEOUT_MS = 5_000

        private const val TAG = "CastReceiver"
    }
}
