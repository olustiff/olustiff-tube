package com.olustiff.app.cast

import android.content.Context
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
    private var stateJson: String = "null"

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
                stateJson = encodeState(call.arguments)
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
                respond(client, 200, """{"ok":true,"state":$stateJson}""")

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
        val payload = mapOf(
            "action" to action,
            "positionMs" to (json?.optLong("positionMs") ?: 0L)
        )
        mainHandler.post { channel.invokeMethod("castCommand", payload) }
        respond(client, 200, """{"ok":true}""")
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

    /** Flutter'dan gelen durum haritasını JSON'a çevirir. */
    private fun encodeState(arguments: Any?): String {
        val map = arguments as? Map<*, *> ?: return "null"
        return JSONObject().apply {
            put("videoId", map["videoId"] ?: JSONObject.NULL)
            put("title", map["title"] ?: JSONObject.NULL)
            put("positionMs", map["positionMs"] ?: 0)
            put("durationMs", map["durationMs"] ?: JSONObject.NULL)
            put("isPlaying", map["isPlaying"] ?: false)
        }.toString()
    }

    companion object {
        const val CHANNEL = "olustiff/cast"

        /** Protokol sabitleri Dart tarafındaki `cast_protocol.dart` ile aynı olmalı. */
        private const val MAGIC = "olustiff-cast"
        private const val PROTOCOL_VERSION = 1
        private const val DISCOVERY_PORT = 45632
        private const val CONTROL_PORT = 45633

        private val COMMANDS =
            setOf("resume", "pause", "seek", "next", "previous", "stop")

        private const val HEADER_END = 0x0D0A0D0A
        private const val MAX_HEADER_BYTES = 8 * 1024
        private const val MAX_BODY_BYTES = 64 * 1024
        private const val SOCKET_TIMEOUT_MS = 5_000

        private const val TAG = "CastReceiver"
    }
}
