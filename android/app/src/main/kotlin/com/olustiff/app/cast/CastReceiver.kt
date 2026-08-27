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
 * Alıcının ÖMRÜ aktiviteye bağlı DEĞİL: sahibi [CastReceiverService] adlı
 * ön plan servisi ve servis açılışta (BOOT_COMPLETED) başlıyor. Televizyonda
 * uygulama hiç açılmamış olsa bile cihaz keşifte görünür ve gelen yayın
 * isteği uygulamayı KENDİSİ açar.
 *
 * Bu yüzden Flutter kanalı zorunlu değil, TAKILABİLİR ([attach]/[detach]):
 * uygulama kapalıyken kanal yoktur; gelen istek [pendingCast] olarak saklanır,
 * uygulama açılıp kanalı taktığında iletilir.
 */
class CastReceiver(
    private val context: Context,
    /** Uygulamayı öne getirir; yayın isteği geldiğinde çağrılır. */
    private val bringToFront: () -> Unit
) {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var running = false

    // @Volatile: soketler işçi thread'lerde açılıyor, [stop] ana thread'den
    // çağrılıyor. İşaretlenmezse [stop] bayat (null) değer okuyup soketleri
    // kapatamıyor; thread'ler accept/receive üzerinde sonsuza kadar bloke
    // kalıyor ve portlar bağlı kalıyordu.
    @Volatile
    private var udpSocket: DatagramSocket? = null

    @Volatile
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

    /**
     * Flutter kanalı; uygulama kapalıyken null.
     *
     * @Volatile: kanal ana thread'de takılıp sökülüyor, HTTP thread'i okuyor.
     */
    @Volatile
    private var channel: MethodChannel? = null

    /**
     * Uygulama açılana kadar bekleyen yayın isteği.
     *
     * Televizyonda uygulama kapalıyken istek geldiğinde Flutter tarafı henüz
     * yok. İsteği burada tutup uygulama açıldığında ([attach]) iletiyoruz;
     * yoksa uygulama açılır ama boş ekranda kalırdı.
     *
     * Yalnızca SON istek saklanıyor: kullanıcı arka arkaya iki video
     * gönderdiyse görmek istediği sonuncusu.
     */
    @Volatile
    private var pendingCast: Map<String, Any?>? = null

    /** Uygulama açıldı: bundan sonra istekler doğrudan Flutter'a gider. */
    @Synchronized
    fun attach(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler { call, result -> handleMethod(call, result) }
    }

    /**
     * Uygulama kapandı: kanal bırakılıyor ama AĞ DİNLEYİCİSİ AÇIK KALIYOR.
     *
     * Eskiden alıcı aktiviteyle birlikte kapanıyordu; televizyonda uygulama
     * kapalıyken telefon cihazı hiç bulamıyordu (kullanıcının bildirdiği
     * "aynı ağda ama bulamıyor" sorununun sebebi buydu).
     */
    @Synchronized
    fun detach(channel: MethodChannel) {
        // Başka bir aktivite bu arada kendi kanalını taktıysa onu sökmüyoruz.
        if (this.channel !== channel) return
        channel.setMethodCallHandler(null)
        this.channel = null
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startReceiver" -> {
                val ready = start()
                result.success(ready)
                // Uygulama, yayın isteği YÜZÜNDEN açılmış olabilir; kanal yeni
                // takıldığı için bekleyen isteği şimdi iletiyoruz.
                if (ready) flushPending()
            }

            "publishState" -> {
                playbackState = call.arguments as? Map<*, *>
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------- yaşam döngüsü

    /** Alıcı gerçekten dinlemeye başladıysa true döner. */
    @Synchronized
    fun start(): Boolean {
        if (running) return true

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

        // Bağlama (bind) THREAD'DEN ÖNCE ve burada yapılıyor: eskiden
        // döngünün içindeydi, hatası sessizce yutuluyordu ve televizyon
        // keşifte görünüp hiçbir komutu çalıştırmıyordu — kullanıcıya
        // "gönderildi" deniyor ama hiçbir şey olmuyordu.
        val bound = runCatching {
            udpSocket = DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                bind(InetSocketAddress(DISCOVERY_PORT))
            }
            serverSocket = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(CONTROL_PORT))
            }
        }.isSuccess

        if (!bound) {
            Log.w(TAG, "Portlar bağlanamadı; alıcı açılmıyor")
            stop()
            return false
        }

        running = true
        startThread("olustiff-cast-udp", ::runDiscoveryLoop)
        startThread("olustiff-cast-http", ::runHttpLoop)
        return true
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
        val socket = udpSocket ?: return
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
        val server = serverSocket ?: return
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
        // İstek ÖNCE saklanıyor: uygulama kapalıysa açılması saniyeler sürüyor
        // ve o sırada isteği tutacak başka bir yer yok.
        pendingCast = payload
        mainHandler.post {
            // Önce öne getir: televizyon başka bir uygulamadaysa (ya da uygulama
            // hiç açık değilse) video arkada açılıp kimse görmezdi.
            runCatching { bringToFront() }
                .onFailure { Log.w(TAG, "Uygulama öne getirilemedi", it) }
            // Uygulama zaten açıksa istek burada iletilir; kapalıysa Flutter
            // açılıp `startReceiver` çağırdığında iletilecek.
            flushPending()
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

        // Uygulama kapalıyken oynatma da yok: "duraklat"/"sonraki" gibi
        // komutları sessizce yutup "oldu" demek telefona yalan söylemek olurdu.
        val target = channel
        if (target == null) {
            respond(client, 503, """{"ok":false,"error":"app_not_running"}""")
            return
        }

        val payload = mapOf(
            "action" to action,
            "positionMs" to (json?.optLong("positionMs") ?: 0L)
        )
        mainHandler.post { target.invokeMethod("castCommand", payload) }
        respond(client, 200, """{"ok":true}""")
    }

    /**
     * Bekleyen yayın isteğini Flutter'a iletir.
     *
     * Kanal yoksa istek BEKLEMEYE devam eder — uygulama açılıp kanalı
     * taktığında `startReceiver` üzerinden yeniden denenir.
     */
    private fun flushPending() {
        val target = channel ?: return
        val payload = pendingCast ?: return
        pendingCast = null
        runCatching { target.invokeMethod("castPlay", payload) }
            .onFailure { Log.w(TAG, "Bekleyen yayın isteği iletilemedi", it) }
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
                    // Alan eksikse sesi SIFIRLAMIYORUZ: eskiden eksik istek
                    // sessizce televizyonu susturup "ok" dönüyordu.
                    val level = json?.opt("volume") as? Number ?: return false
                    val index =
                        (level.toDouble().coerceIn(0.0, 1.0) * max).roundToInt()
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
                    // Cihazın kendi kademesi ölçeğe göre değişiyor; sabit
                    // oranlı adım her cihazda aynı hissi veriyor.
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

        /**
         * Bir ses düğmesi basışının oynattığı oran.
         *
         * Televizyonun ölçeği 0..100 olduğu için tam 2 birime denk geliyor.
         * Telefondaki karşılığıyla aynı tutulmalı (CastController.volumeStep).
         */
        private const val VOLUME_STEP = 0.02

        private const val HEADER_END = 0x0D0A0D0A
        private const val MAX_HEADER_BYTES = 8 * 1024
        private const val MAX_BODY_BYTES = 64 * 1024
        private const val SOCKET_TIMEOUT_MS = 5_000

        private const val TAG = "CastReceiver"
    }
}
