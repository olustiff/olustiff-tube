package com.olustiff.app.player

import android.content.Context
import com.olustiff.app.diag.Tanilama
import android.net.Uri
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.dash.manifest.DashManifestParser
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import com.olustiff.app.extractor.ExtractionService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.IOException
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Uygulama boyunca TEK bir ExoPlayer örneği.
 *
 * Neden singleton: video yüzeyi (PlatformView) ile arka plan medya oturumu
 * ([PlaybackService]) aynı player'ı paylaşmak zorunda. Böylece kullanıcı video
 * ekranından çıktığında oynatma kesilmez — sadece görüntü yüzeyi ayrılır, ses
 * akmaya devam eder. Ekrana geri dönüldüğünde yüzey yeniden bağlanır; hiçbir
 * zaman "yeniden baştan başlatma" ya da "kendiliğinden video moduna atlama"
 * olmaz.
 */
object PlayerHolder {

    private var exoPlayer: ExoPlayer? = null
    private var dataSourceFactory: DataSource.Factory? = null

    /** Arama/bildirim geldiğinde duraklatmayı sağlayan ses odağı yöneticisi. */
    private var audioFocus: AudioFocusHandler? = null

    /** Sesi YouTube seviyesine yaklaştıran kazanç. */
    private val loudness = LoudnessBoost()

    /** Kullanıcının seçtiği mod. Uygulamanın hiçbir yerinde otomatik değişmez. */
    @Volatile
    var audioOnlyMode: Boolean = false
        private set

    /**
     * Kullanıcının seçtiği kalite tavanı; `null` = "Otomatik".
     *
     * Kuyrukta sıradakine geçiş NATIVE tarafta yapıldığı için (ekran kapalıyken
     * de ilerlemeli) tercih burada da tutulmak zorunda: Dart o anda uykuda
     * olabilir ve seçimi yapamaz.
     */
    @Volatile
    var preferredMaxHeight: Int? = null

    /** Çalan medya uyarlanabilir bir manifestten mi geliyor. */
    @Volatile
    private var adaptiveQuality: Boolean = false

    /** Mevcut medyanın, moddan bağımsız olarak saklanan kaynakları. */
    private var currentRequest: PlayRequest? = null

    data class PlayRequest(
        val videoUrl: String?,
        val audioUrl: String,
        val title: String,
        val artist: String?,
        val artworkUrl: String?,
        /**
         * Canlı yayınlarda [audioUrl] bir HLS manifest adresidir ve ayrık
         * video/ses parçaları bulunmaz; oynatma tek bir HLS kaynağından yapılır.
         */
        val isLive: Boolean = false
    )

    /** Kuyruk ilerlediğinde Flutter'a haber vermek için (UI açıksa günceller). */
    @Volatile
    var onQueueAdvanced: (() -> Unit)? = null

    /**
     * Geçerli medyanın ilk video karesi çizildi mi.
     *
     * Yeni bir medya yüklenirken ExoPlayer yüzeyde ESKİ videonun son karesini
     * tutar; arayüz bunu göstermek yerine kapak + yükleme göstergesi çizsin
     * diye bu bayrağı izler.
     */
    @Volatile
    var hasVideoFrame: Boolean = false
        private set

    /** Otomatik geçiş sırasında yeni bir bitiş olayının araya girmesini önler. */
    @Volatile
    private var advancing = false

    @Synchronized
    fun getPlayer(context: Context): ExoPlayer {
        exoPlayer?.let { return it }
        val appContext = context.applicationContext
        Tanilama.init(appContext)
        return ExoPlayer.Builder(appContext)
            // Bant genişliği tahmini DÜŞÜKTEN başlıyor.
            //
            // Ölçümde görülen şey: akış yavaş fazda ~277 kbps'te sabitlenip
            // sonra birkaç Mbps'e fırlıyor. Oynatıcı iyimser bir başlangıç
            // tahminiyle yüksek çözünürlüğü seçince yavaş faz tamponu
            // boşaltıyor, video birkaç saniye oynayıp donuyordu — ilk
            // ölçümler aktarımın gerçek zamanın %7'sinde kaldığını gösterdi.
            //
            // Düşük tahminle ilk parça küçük bir çözünürlükten geliyor, tampon
            // hızla doluyor ve hız elverdiğinde oynatıcı kendiliğinden
            // yukarı tırmanıyor. YouTube'un kendi uygulaması da böyle
            // davranıyor: yüksekten başlayıp donmak yerine düşükten başlayıp
            // açılıyor.
            .setBandwidthMeter(
                DefaultBandwidthMeter.Builder(appContext)
                    .setInitialBitrateEstimate(INITIAL_BITRATE_ESTIMATE)
                    .build()
            )
            // Tampon hedefi büyük tutuluyor ki hızlı fazlar yavaş fazları
            // karşılayabilsin; ama OYNATMAYA BAŞLAMA eşiği küçük.
            //
            // Eşik bir ara 6 saniyeye çıkarılmıştı ve yanlıştı: her parça
            // geçişine 6 saniye sessizlik ekliyordu, bir takılmadan sonra 12.
            // Çıkarma süresiyle toplanınca arabada "müzik durdu" demek
            // oluyordu. Düşük başlangıç tahmini (bkz. yukarısı) zaten küçük
            // bir parçadan başlatıyor, uzun beklemeye gerek yok.
            //
            // Üst sınır da 180 saniyeden indirildi: video modunda 1080p'de
            // o kadar tampon onlarca MB demek ve düşük bellekli cihazda
            // çöp toplayıcıyı zorluyor.
            .setLoadControl(
                DefaultLoadControl.Builder()
                    .setBufferDurationsMs(
                        /* minBufferMs= */ 50_000,
                        /* maxBufferMs= */ 90_000,
                        /* bufferForPlaybackMs= */ 2_000,
                        /* bufferForPlaybackAfterRebufferMs= */ 5_000
                    )
                    .build()
            )
            // Ses türü bildiriliyor (doğru ses yönlendirmesi için), ama odak
            // yönetimi Media3'e BIRAKILMIYOR: otomatik yönetim telefon
            // aramalarında çoğu cihazda duraklatmak yerine sesi kısıyordu.
            // Odağı [AudioFocusHandler] yönetiyor.
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                /* handleAudioFocus= */ false
            )
            // Kulaklık/bluetooth çıkarıldığında duraklat — hoparlörden
            // aniden çalmaya başlamasın.
            .setHandleAudioBecomingNoisy(true)
            // Ekran kapalıyken CPU ve Wi-Fi uyanık kalsın; aksi hâlde arka
            // planda müzik kesilebilir.
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
            .also { player ->
            exoPlayer = player
            audioFocus = AudioFocusHandler(appContext, player)
            player.addAnalyticsListener(loadLogger)
            stallWatch.start(appContext)
            loudness.attach(player.audioSessionId)
            // Otomatik geçiş NATIVE tarafta dinleniyor: ekran kapalıyken de
            // parça bitince sıradakine geçilmeli. Bu dinleyici Dart'ta olsaydı
            // Flutter motoru askıya alındığında hiç tetiklenmezdi.
            player.addListener(object : Player.Listener {
                // Ses oturumu yeniden kurulduğunda (ör. çıkış cihazı değişince)
                // efekt eski oturuma bağlı kalıyor ve ses tekrar kısılıyordu.
                override fun onAudioSessionIdChanged(audioSessionId: Int) {
                    loudness.attach(audioSessionId)
                }

                override fun onRenderedFirstFrame() {
                    hasVideoFrame = true
                    onQueueAdvanced?.invoke()
                }

                // "Otomatik" seçiliyken oynatılan çözünürlük bant genişliğiyle
                // birlikte değişiyor; kullanıcı o an neyi izlediğini görebilsin
                // diye etiket her değişimde güncelleniyor.
                override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
                    if (!adaptiveQuality) return
                    val height = videoSize.height
                    currentQualityLabel = if (height > 0) {
                        "${StreamSelector.AUTO_LABEL} • ${height}p"
                    } else {
                        StreamSelector.AUTO_LABEL
                    }
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    trackBuffering(player, playbackState)
                    if (playbackState == Player.STATE_READY) stallWatch.reset()
                    if (playbackState != Player.STATE_ENDED) return
                    if (!PlaybackQueue.autoplay || advancing) return
                    advancing = true
                    scope.launch {
                        try {
                            playNext(appContext, manual = false)
                        } catch (e: Exception) {
                            // Buradaki `catch` HAYATİ: bu kapsam
                            // `SupervisorJob` kullanıyor ve yakalanmayan bir
                            // istisna doğrudan sistemin "uygulamayı öldür"
                            // işleyicisine gidiyor. Gerçek cihazda tam olarak
                            // bu oldu (bkz. [playNext] belgesi).
                            Tanilama.olay(TAG, "Sıradakine geçilemedi", e)
                        } finally {
                            advancing = false
                        }
                    }
                }
            })
        }
    }

    /**
     * Oynatma işlerinin kapsamı.
     *
     * [CoroutineExceptionHandler] son savunma hattı: tek tek `catch`'ler
     * atlandığında bile yakalanmayan bir istisnanın uygulamayı öldürmesini
     * engelliyor. Oynatma arka planda, kullanıcı başka bir uygulamadayken de
     * sürüyor; orada çökmek en kötü sonuç.
     */
    private val scope = CoroutineScope(
        SupervisorJob() +
            Dispatchers.Main +
            CoroutineExceptionHandler { _, e ->
                Tanilama.olay(TAG, "Oynatma işi başarısız", e)
            }
    )

    /** Kuyrukta art arda kaç parça denenecek. */
    private const val MAX_ADVANCE_ATTEMPTS = 3

    private const val TAG = "OlustiffPlayer"

    /**
     * Kuyruktaki bir videoyu id'sinden çözüp çalar.
     *
     * Çözümleme (extraction) burada, native tarafta yapılıyor; böylece geçiş
     * uygulamanın açık olmasına bağlı değil.
     */
    private suspend fun playQueueItem(context: Context, item: PlaybackQueue.Item) {
        val info = withContext(Dispatchers.IO) {
            ExtractionService.streamInfo(item.videoId)
        }
        val selection =
            StreamSelector.select(info, audioOnlyMode, preferredMaxHeight) ?: return
        currentQualityLabel = selection.qualityLabel
        play(
            context,
            PlayRequest(
                videoUrl = selection.videoUrl,
                audioUrl = selection.audioUrl,
                title = info.name ?: item.title,
                artist = info.uploaderName ?: item.uploaderName,
                artworkUrl = item.thumbnailUrl,
                isLive = selection.isLive
            ),
            audioOnlyMode
        )
        onQueueAdvanced?.invoke()
    }

    /** En son çalınan medyanın kalite etiketi (arayüzde gösterilir). */
    @Volatile
    var currentQualityLabel: String? = null

    /**
     * Ekranın uyanık tutulması gerekip gerekmediğini arayüze bildirir:
     * video izlenirken ekran kapanmamalı, sesli modda ise kapanabilmeli.
     */
    @Volatile
    var onKeepScreenOnChanged: ((Boolean) -> Unit)? = null

    /** Videonun en/boy oranı; arayüz kutuyu buna göre ölçekler. */
    @Volatile
    var videoAspectRatio: Double = 16.0 / 9.0
        private set

    /**
     * Video çıktısını verilen yüzeye yönlendirir. `null` verilirse yalnızca
     * görüntü ayrılır; oynatma (ses) etkilenmez.
     */
    fun setVideoSurface(surface: android.view.Surface?) {
        val player = exoPlayer ?: return
        if (surface == null) player.clearVideoSurface() else player.setVideoSurface(surface)
    }

    /**
     * Kuyrukta sıradakine geçer.
     *
     * Çözümleme AĞ işi ve başarısız olabiliyor. Gerçek cihazdan alınan çökme
     * kaydı bunu gösterdi: arabada hücre değişimi sırasında
     * `UnknownHostException` fırlıyor, hiçbir yerde yakalanmıyor ve sistem
     * uygulamayı ÖLDÜRÜYOR — kullanıcı için "bir sonraki şarkıda uygulama
     * donup kalıyor" demek.
     *
     * Artık başarısız parça kuyruğu bitirmiyor: bir sonraki denenıyor.
     * [MAX_ADVANCE_ATTEMPTS] ile sınırlı, çünkü ağ tamamen yoksa kuyruğun
     * tamamını tek tek denemek yalnızca pili yakar.
     */
    suspend fun playNext(context: Context, manual: Boolean = true) {
        advanceWithRecovery(context) { PlaybackQueue.advance(manual) }
    }

    suspend fun playPrevious(context: Context) {
        advanceWithRecovery(context) { PlaybackQueue.back() }
    }

    suspend fun playAt(context: Context, index: Int) {
        val item = PlaybackQueue.jumpTo(index) ?: return
        runCatching { playQueueItem(context, item) }
            .onFailure { Tanilama.olay(TAG, "Seçilen parça açılamadı: ${item.videoId}", it) }
    }

    /**
     * [nextItem] ile ilerleyip çalar; başarısız olursa bir sonrakine geçer.
     *
     * Hata YUTULMUYOR, günlüğe yazılıyor: sessizce duran bir oynatıcı ile
     * ağın kopuk olduğunu anlamak arasındaki fark bu.
     */
    private suspend fun advanceWithRecovery(
        context: Context,
        nextItem: () -> PlaybackQueue.Item?
    ) {
        // Yeni bir ilerleme isteği, ağ bekleyen eskisini geçersiz kılıyor:
        // ikisi birden ağ gelince parça açmaya çalışmasın.
        val generation = ++playGeneration
        var networkRetries = 0
        var attempts = 0
        var item = nextItem() ?: return
        while (attempts < MAX_ADVANCE_ATTEMPTS) {
            try {
                playQueueItem(context, item)
                return
            } catch (e: CancellationException) {
                // İptal bir hata değil: yeni bir oynatma isteği geldi.
                throw e
            } catch (e: Exception) {
                // AĞ HATASINDA PARÇA ATLANMIYOR. Cihazda kalıcı günlükle
                // görüldü: ağ geçiş anında koptuğunda üç parça aynı saniyede
                // denenip "açılabilen parça yok" deniyor, müzik duruyor ve ağ
                // geri gelince de başlamıyordu (arabada tünel, çekmeyen yol).
                // Ağ yoksa sıradaki parça da açılmaz; atlamak yalnızca
                // şarkı kaybettirir. Ağ beklenip AYNI parça yeniden deneniyor.
                if (isNetworkError(e) && networkRetries < MAX_NETWORK_RETRIES) {
                    networkRetries++
                    Tanilama.olay(TAG, "Ağ hatası, ağ bekleniyor: ${item.videoId}", e)
                    if (!waitForNetwork(context, generation)) return
                    Tanilama.olay(TAG, "Ağ geri geldi, yeniden deneniyor: ${item.videoId}")
                    continue
                }
                attempts++
                Tanilama.olay(TAG, "Parça açılamadı, sıradakine geçiliyor: ${item.videoId}", e)
                if (generation != playGeneration) return
                item = nextItem() ?: return
            }
        }
        Tanilama.olay(TAG, "Kuyrukta açılabilen parça bulunamadı")
    }

    /**
     * Her yeni oynatmada artıyor. Ağ beklenirken kullanıcı başka bir şey
     * seçtiyse bekleyen deneme bunu görüp vazgeçiyor; yoksa ağ gelince
     * kullanıcının seçiminin üstüne eski parçayı açardı.
     */
    @Volatile
    private var playGeneration = 0

    /**
     * Ses çıkışı (Bluetooth/kulaklık) koptu ve kullanıcı o zamandan beri
     * hiçbir şeye basmadı.
     *
     * Kilitliyken HİÇBİR otomatik mekanizma (odak dönüşü, ağ geri gelince
     * yeniden deneme, takılma bekçisi, adres tazeleme, sıradaki parça) sesi
     * başlatamıyor. Gerçek kullanımda görülen: arabanın Bluetooth'u koptu,
     * müzik TELEFONUN HOPARLÖRÜNDEN çalmaya devam etti. Sebep: araba
     * koparken önce ses odağını kısa süreliğine alıyor (oynatıcı "geçici
     * kesinti" deyip duruyor), sonra Bluetooth kopuyor, odak telefona dönünce
     * "kesinti bitti" sanılıp çalma yeniden başlatılıyordu. Oynatıcının kendi
     * "kulaklık çıktı" koruması yalnızca ÇALARKEN dinlediği için o anda
     * devrede değildi.
     *
     * Kilidi yalnızca kullanıcının bir komutu ([userIntent]) ya da Bluetooth'un
     * yeniden bağlanması açıyor.
     */
    @Volatile
    var outputLost = false
        private set

    /** Çıkış koptu: duraklat ve otomatik başlatmayı kilitle. */
    fun onOutputLost(reason: String) {
        val wasPlaying = exoPlayer?.playWhenReady == true
        // İki kaynak (sistem yayını + cihaz listesi) aynı kopmayı bildirebiliyor.
        if (outputLost && !wasPlaying) return
        outputLost = true
        exoPlayer?.playWhenReady = false
        Tanilama.olay(TAG, "Ses çıkışı koptu ($reason), ${if (wasPlaying) "duraklatıldı" else "zaten duruyordu"}; otomatik başlatma kilitli")
    }

    /** Kullanıcı bilerek bir şey istedi: çıkış kilidi kalkar. */
    fun userIntent() {
        if (!outputLost) return
        outputLost = false
        Tanilama.olay(TAG, "Kullanıcı komutu, çıkış kilidi kalktı")
    }

    private fun isNetworkError(e: Throwable): Boolean =
        generateSequence(e) { it.cause }.take(8).any { it is IOException }

    /**
     * İnternet gelene kadar bekler (en fazla [NETWORK_WAIT_MS]).
     *
     * Dönüş: yeniden denemeye değer mi. Süre dolduysa ya da bu arada yeni bir
     * oynatma başladıysa false.
     */
    private suspend fun waitForNetwork(context: Context, generation: Int): Boolean {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        val deadline = android.os.SystemClock.elapsedRealtime() + NETWORK_WAIT_MS
        // İlk deneme hemen değil: kopma anında ağ "var" görünüp yine de
        // isim çözülemiyor olabiliyor; kısa bir nefes aynı hatayı tekrarlamaz.
        delay(NETWORK_POLL_MS)
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            if (generation != playGeneration) return false
            val caps = runCatching { cm.getNetworkCapabilities(cm.activeNetwork) }.getOrNull()
            if (caps?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) {
                return true
            }
            delay(NETWORK_POLL_MS)
        }
        Tanilama.olay(TAG, "Ağ ${NETWORK_WAIT_MS / 60_000} dk içinde gelmedi, bekleme bırakıldı")
        return false
    }

    private const val MAX_NETWORK_RETRIES = 5
    private const val NETWORK_WAIT_MS = 5 * 60_000L
    private const val NETWORK_POLL_MS = 2_000L

    /**
     * Yükleme hatalarını günlüğe yazar.
     *
     * "Yavaş yükleme" bilerek YAZILMIYOR: oynatıcı 90 sn'lik tampon dolunca
     * okumayı kendisi yavaşlatıyor, yani bir yüklemenin süresi şarkının
     * süresine yayılıyor ve hız ağ hakkında hiçbir şey söylemiyor. İlk sürüm
     * bunu yazıyordu ve kayıtları yanlış alarmla dolduruyordu. Gerçek
     * takılmayı "Bekleme" satırları ölçüyor.
     *
     * Oynatıcı ağ hatalarını SESSİZCE yeniden deniyor; kullanıcı yalnızca
     * "dondu" görüyor, günlükte hiçbir iz kalmıyordu. Donmanın sebebini
     * (hangi sunucu, ne kadar sürdü, hangi hata) görmenin tek yolu bu.
     */
    private val loadLogger = object : AnalyticsListener {
        override fun onLoadError(
            eventTime: AnalyticsListener.EventTime,
            loadEventInfo: LoadEventInfo,
            mediaLoadData: MediaLoadData,
            error: IOException,
            wasCanceled: Boolean
        ) {
            Tanilama.olay(
                TAG,
                "Yükleme hatası (tür=${mediaLoadData.trackType}, " +
                    "${loadEventInfo.loadDurationMs} ms, " +
                    "${loadEventInfo.uri.host}): ${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }


    /** Süren bekleme (yükleniyor) başlangıcı; yoksa 0. */
    private var bufferingSince = 0L
    private var bufferingAt = 0L

    /**
     * Her "yükleniyor" beklemesinin süresini kalıcı günlüğe yazar.
     *
     * Kullanıcının "donuyor" dediği şeyin ölçüsü bu: kaç saniye, parçanın
     * açılışında mı ortasında mı. Kısa beklemeler (ör. normal açılış)
     * gürültü olmasın diye [BUFFERING_LOG_MS] altı yazılmıyor.
     */
    private fun trackBuffering(player: ExoPlayer, state: Int) {
        val now = android.os.SystemClock.elapsedRealtime()
        when {
            state == Player.STATE_BUFFERING && player.playWhenReady -> {
                if (bufferingSince == 0L) {
                    bufferingSince = now
                    bufferingAt = player.currentPosition
                }
            }
            bufferingSince != 0L -> {
                val waited = now - bufferingSince
                bufferingSince = 0L
                if (state != Player.STATE_READY || waited < BUFFERING_LOG_MS) return
                val where = if (bufferingAt < 1_000) "açılışta" else "${bufferingAt / 1000}. saniyede"
                val mode = if (audioOnlyMode) "ses" else "video"
                Tanilama.olay(
                    TAG,
                    "Bekleme ${"%.1f".format(Locale.ROOT, waited / 1000.0)} sn, $where " +
                        "($mode, ${PlaybackQueue.current()?.videoId})"
                )
            }
        }
    }

    private const val BUFFERING_LOG_MS = 3_000L

    /**
     * Dosyanın başından yapılan isteğe `Range: bytes=0-` ekler.
     *
     * TAKILMALARIN ASIL SEBEBİ BU. Oynatıcı dosyayı baştan sonuna okurken
     * Range başlığı göndermiyor (yalnızca ileri sarınca gönderiyor) ve
     * YouTube Range'siz isteği gerçek zamanlı hıza kısıyor. Cihazda, mobil
     * veride, aynı adresle ölçüldü:
     *
     *   Range yok        ~30 KB/s  (≈240 kbps)
     *   Range: bytes=0-  ~3.2 MB/s (≈26 Mbps)
     *
     * Ses modunda (Opus ~160 kbps) bu zar zor yetiyordu: açılış yavaş,
     * en küçük ağ dalgalanmasında takılma. Video modunda 480p bile ~1 Mbps
     * istiyor; ilk birkaç saniyelik tampon bitince oynatıcı "bağlanıyor"a
     * düşüyordu.
     *
     * Yalnızca konum 0 ve uzunluk belirsizken: diğer durumlarda Range'i
     * OkHttpDataSource zaten kendisi ekliyor, ikinci bir başlık çakışırdı.
     */
    private fun withRangeHeader(spec: DataSpec): DataSpec {
        if (spec.position != 0L || spec.length != C.LENGTH_UNSET.toLong()) return spec
        if (spec.uri.scheme?.startsWith("http") != true) return spec
        return spec.withAdditionalHeaders(mapOf("Range" to "bytes=0-"))
    }

    /**
     * Akış adresinin hangi IP ve istemci için verildiğini günlüğe yazar.
     *
     * YouTube adresleri isteyen IP'ye bağlıyor; adres başka bir IP'den
     * indirilmeye çalışılırsa 403 dönüyor. Mobil veride (operatör NAT'ı)
     * dış IP bağlantıdan bağlantıya değişebildiği için bu, donmaların
     * birincil şüphelisi.
     */
    private fun logStreamOrigin(request: PlayRequest) {
        // Yalnızca ip ve istemci yazılıyor; adresin tamamı imza taşıyor.
        val url = request.audioUrl.takeIf { it.startsWith("http") } ?: return
        val uri = Uri.parse(url)
        Log.i(TAG, "Akış: ip=${uri.getQueryParameter("ip")} c=${uri.getQueryParameter("c")}")
    }

    /**
     * Takılma bekçisi: çalması gereken oynatıcı tamponda İLERLEMEDEN
     * bekliyorsa adresleri tazeleyip kaldığı yerden sürdürür.
     *
     * Cihazda ölçülen durum: yeni parçanın başında oynatıcı ~50 sn "yükleniyor"
     * dedi; bu sürede hiçbir hata bildirilmedi (oynatıcı zaman aşımlarını
     * kendi içinde sessizce yeniden deniyor), sonra parçanın tamamı bir anda
     * geldi. Hata bildirilmediği için hata üzerine çalışan kurtarma hiç
     * devreye girmiyordu.
     *
     * Parça başına BİR KEZ: tazelenmiş adres de ilerlemiyorsa sorun ağdadır
     * (ör. kapsama dışı) ve tekrar tekrar çözümlemek yalnızca pil yakar.
     */
    private val stallWatch = object : Runnable {
        private val handler = android.os.Handler(android.os.Looper.getMainLooper())
        private var context: Context? = null
        private var lastBuffered = -1L
        private var stuckSince = 0L
        private var recoveredFor: String? = null

        fun start(appContext: Context) {
            context = appContext
            handler.removeCallbacks(this)
            handler.postDelayed(this, STALL_CHECK_MS)
        }

        /** Parça akmaya başladı: bir sonraki takılmada yeniden deneme hakkı var. */
        fun reset() {
            recoveredFor = null
            stuckSince = 0L
        }

        override fun run() {
            handler.postDelayed(this, STALL_CHECK_MS)
            val player = exoPlayer ?: return
            val waiting = player.playWhenReady &&
                player.playbackState == Player.STATE_BUFFERING &&
                currentRequest != null
            if (!waiting) {
                stuckSince = 0L
                return
            }
            val buffered = player.bufferedPosition
            val now = android.os.SystemClock.elapsedRealtime()
            if (buffered != lastBuffered || stuckSince == 0L) {
                lastBuffered = buffered
                stuckSince = now
                return
            }
            if (now - stuckSince < STALL_LIMIT_MS) return

            val videoId = PlaybackQueue.current()?.videoId ?: return
            if (recoveredFor == videoId) return
            recoveredFor = videoId
            stuckSince = 0L
            Tanilama.olay(TAG, "Takılma: ${STALL_LIMIT_MS / 1000} sn ilerleme yok, adres tazeleniyor ($videoId)")
            val ctx = context ?: return
            scope.launch {
                try {
                    recoverCurrent(ctx)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Tanilama.olay(TAG, "Takılmadan kurtarılamadı", e)
                }
            }
        }
    }

    private const val STALL_CHECK_MS = 2_000L
    private const val STALL_LIMIT_MS = 12_000L

    /**
     * Oynatıcının başlangıç bant genişliği tahmini (bit/sn).
     *
     * Media3'ün varsayılanı ülkeye göre birkaç Mbps; bu akışlarda o tahmin
     * gerçekleşmiyor ve ilk seçim fazla yüksek kalıyor. 700 kbps, 360p'yi
     * rahatça taşıyan ama yanılma payı bırakan bir başlangıç.
     */
    private const val INITIAL_BITRATE_ESTIMATE = 700_000L

    /**
     * Oynatıcıda sürdürülebilir bir medya var mı (çalıyor ya da duraklatılmış;
     * bitmiş ya da hatada kalmış parça sayılmaz).
     *
     * Bluetooth otomatik çalma bunu soruyor: elde zaten bir şey varsa onu
     * kaldığı yerden sürdürmek gerekiyor, kayıtlı parçayı baştan açmak değil.
     */
    val hasMedia: Boolean
        get() = currentRequest != null && exoPlayer?.playbackState.let {
            it == Player.STATE_READY || it == Player.STATE_BUFFERING
        }

    /**
     * Çalan parçayı TAZE adreslerle yeniden açar ve kaldığı yerden sürdürür.
     *
     * Oynatıcı kaynak hatası verdiğinde (ör. `ERROR_CODE_IO_BAD_HTTP_STATUS`)
     * oradan kendiliğinden ÇIKMIYOR: `ERROR` durumunda kalıyor, hiçbir şey
     * çalmıyor ve kullanıcı bunu "uygulama dondu" olarak görüyor. Gerçek
     * cihazda sesli moda geçerken yaşandı — YouTube'un akış adresleri bir
     * süre sonra reddediliyor ve elimizdeki adres artık geçersiz.
     *
     * Çözüm adresi yenilemek: video yeniden çözülüyor, aynı moda ve aynı
     * konuma geri dönülüyor.
     */
    suspend fun recoverCurrent(context: Context) {
        val item = PlaybackQueue.current() ?: return
        val position = exoPlayer?.currentPosition ?: 0L
        val wasPlaying = exoPlayer?.playWhenReady ?: true
        val info = withContext(Dispatchers.IO) {
            // Önbellekteki kayıt tam da reddedilen adresleri taşıyor;
            // silinmezse "yenileme" aynı adresi yeniden açardı.
            ExtractionService.forget(item.videoId)
            ExtractionService.streamInfo(item.videoId)
        }
        val selection =
            StreamSelector.select(info, audioOnlyMode, preferredMaxHeight) ?: return
        currentQualityLabel = selection.qualityLabel
        play(
            context,
            PlayRequest(
                videoUrl = selection.videoUrl,
                audioUrl = selection.audioUrl,
                title = info.name ?: item.title,
                artist = info.uploaderName ?: item.uploaderName,
                artworkUrl = item.thumbnailUrl,
                isLive = selection.isLive
            ),
            audioOnlyMode
        )
        if (position > 0 && !selection.isLive) exoPlayer?.seekTo(position)
        // Kullanıcı duraklatmışken gelen hata, oynatmayı kendiliğinden başlatmasın.
        exoPlayer?.playWhenReady = wasPlaying && !outputLost
    }

    /** Duraklatılmış oynatmayı sürdürür; yüklü medya yoksa hiçbir şey yapmaz. */
    fun resume() {
        if (currentRequest == null) return
        // Çağıranlar: Bluetooth yeniden bağlandı ya da kullanıcı istedi.
        outputLost = false
        exoPlayer?.playWhenReady = true
    }

    /** Ses yükseltme kazancını değiştirir (milibel; 0 = kapalı). */
    fun setLoudnessGain(millibels: Int) {
        loudness.setGain(millibels)
    }

    @Synchronized
    private fun getDataSourceFactory(): DataSource.Factory {
        // Zaman aşımları kısa: YouTube sunucusu bazen bağlantıyı açık tutup
        // hiç veri göndermiyor. Varsayılan 10 sn'lik bekleme, oynatıcının
        // sessiz yeniden denemeleriyle çarpılınca cihazda ~50 sn donma
        // olarak ölçüldü (bkz. [StallWatch]).
        val http = OkHttpDataSource.Factory(
            OkHttpClient.Builder()
                .connectTimeout(6, TimeUnit.SECONDS)
                .readTimeout(6, TimeUnit.SECONDS)
                .build()
        )
            .setUserAgent(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            )
        return dataSourceFactory ?: ResolvingDataSource.Factory(http) { spec ->
            withRangeHeader(spec)
        }.also { dataSourceFactory = it }
    }

    /**
     * Yeni bir medya yükler. [audioOnly] true ise video parçası hiç
     * indirilmez — bu, "arka planda müzik dinleme" modunda hem veri hem pil
     * tasarrufu sağlar ve videoya geçişi yapısal olarak imkansız kılar.
     */
    fun play(context: Context, request: PlayRequest, audioOnly: Boolean) {
        val player = getPlayer(context)
        playGeneration++
        logStreamOrigin(request)
        currentRequest = request
        audioOnlyMode = audioOnly
        adaptiveQuality = !audioOnly && DashManifestBuilder.isManifest(request.videoUrl)
        // Yeni medya: eski karenin "yeni video" sanılmaması için bayrak sıfırlanır.
        hasVideoFrame = false
        applyAudioOnlyTrackSelection(player, request, audioOnly)
        player.setMediaSource(buildSource(request, audioOnly))
        player.prepare()
        // Odak alınamazsa (ör. süren bir arama var) çalmaya başlamıyoruz.
        // Odak istenir ama SONUCU beklenmez: kullanıcı bilerek bir şey
        // açtıysa (süren arama sırasında bile) oynatma başlamalı.
        audioFocus?.request()
        // Çıkış koptuysa (bkz. [outputLost]) parça hazırlanır ama SESSİZ
        // bekler; kullanıcı komutları kilidi önceden kaldırıyor.
        player.playWhenReady = !outputLost
    }

    /**
     * Canlı yayınlarda video ve ses tek manifestte geldiği için kaynağı
     * ayıklayamayız; bunun yerine sesli modda video parçasını devre dışı
     * bırakırız. Canlı olmayan içerikte kısıt kaldırılır, çünkü orada mod
     * zaten kaynak seçimiyle uygulanıyor.
     */
    private fun applyAudioOnlyTrackSelection(
        player: ExoPlayer,
        request: PlayRequest,
        audioOnly: Boolean
    ) {
        // Sesli modda video parçası HER ZAMAN kapatılıyor, yalnızca canlı
        // yayında değil.
        //
        // Gerekçesi [StreamSelector]: ayrık ses akışı bulunmayan videolarda
        // sesli mod artık birleşik akışa düşüyor ve o akış video parçası da
        // taşıyor. Kapatılmazsa ekranı kapalı müzik dinlerken video boşuna
        // çözülür — pil ve veri harcar.
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, audioOnly)
            .build()
    }

    /**
     * Kullanıcı modu elle değiştirdiğinde çağrılır (ör. "sadece ses"e geç).
     * Oynatma konumu korunur — kullanıcı kaldığı yerden devam eder.
     */
    fun setAudioOnly(
        context: Context,
        audioOnly: Boolean,
        videoUrl: String? = null,
        audioUrl: String? = null
    ) {
        val existing = currentRequest ?: return
        if (audioOnly == audioOnlyMode && videoUrl == null && audioUrl == null) return
        audioOnlyMode = audioOnly
        // Sesli modda kaynak yalnızca ses olarak çözülmüştü; videoya geçerken
        // video kaynağı YENİDEN çözülüp verilmezse görüntü hiç gelmez.
        reload(context, existing, videoUrl, audioUrl, audioOnly)
    }

    /**
     * İndirilmiş bir dosyayı oynatır.
     *
     * Yerel dosyada video ve ses zaten tek kapta olduğu için birleştirme
     * yapılmaz; sesli mod, video parçasını devre dışı bırakarak uygulanır.
     *
     * [path] iki biçimde gelebilir: indirmeler artık ortak Müzik klasöründe
     * durduğu için bir `content://` adresi, eski kayıtlar içinse mutlak dosya
     * yolu. ExoPlayer ikisini de okur, yeter ki doğru Uri'ye çevrilsin.
     */
    fun playLocal(
        context: Context,
        path: String,
        title: String,
        artist: String?,
        audioOnly: Boolean
    ) {
        val player = getPlayer(context)
        audioOnlyMode = audioOnly
        currentQualityLabel = null
        adaptiveQuality = false
        hasVideoFrame = false

        val metadata = MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
            .build()

        currentRequest = PlayRequest(
            videoUrl = null,
            audioUrl = path,
            title = title,
            artist = artist,
            artworkUrl = null
        )

        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, audioOnly)
            .build()

        player.setMediaItem(
            MediaItem.Builder()
                .setUri(localUri(path))
                .setMediaMetadata(metadata)
                .build()
        )
        player.prepare()
        // Odak istenir ama SONUCU beklenmez: kullanıcı bilerek bir şey
        // açtıysa (süren arama sırasında bile) oynatma başlamalı.
        audioFocus?.request()
        // Çıkış koptuysa (bkz. [outputLost]) parça hazırlanır ama SESSİZ
        // bekler; kullanıcı komutları kilidi önceden kaldırıyor.
        player.playWhenReady = !outputLost
    }

    /**
     * Mutlak dosya yolu mu, content:// adresi mi olduğunu ayırt eder.
     *
     * Dosya yolu her zaman "/" ile başlar; başka her şey (content://, file://)
     * zaten hazır bir Uri metnidir ve olduğu gibi çözülmelidir — [Uri.fromFile]
     * ile sarmalamak bozuk bir adres üretirdi.
     */
    private fun localUri(path: String): Uri =
        if (path.startsWith("/")) Uri.fromFile(java.io.File(path)) else Uri.parse(path)

    /**
     * Kaynakları değiştirir (ör. kalite seçimi) — mod aynı kalır ve oynatma
     * konumu korunur, böylece kullanıcı kaldığı yerden izlemeye devam eder.
     */
    fun replaceSources(context: Context, videoUrl: String?, audioUrl: String?) {
        val existing = currentRequest ?: return
        reload(context, existing, videoUrl, audioUrl, audioOnlyMode)
    }

    private fun reload(
        context: Context,
        existing: PlayRequest,
        videoUrl: String?,
        audioUrl: String?,
        audioOnly: Boolean
    ) {
        val request = existing.copy(
            videoUrl = videoUrl ?: existing.videoUrl,
            audioUrl = audioUrl ?: existing.audioUrl
        )
        currentRequest = request
        adaptiveQuality = !audioOnly && DashManifestBuilder.isManifest(request.videoUrl)

        val player = getPlayer(context)
        val position = player.currentPosition
        val wasPlaying = player.playWhenReady
        applyAudioOnlyTrackSelection(player, request, audioOnly)

        // Canlı yayında kaynak değişmiyor (aynı HLS manifesti), yalnızca parça
        // seçimi değişiyor — yeniden hazırlamak yayını başa sardırırdı.
        if (!request.isLive) {
            player.setMediaSource(buildSource(request, audioOnly), position)
            player.prepare()
            player.playWhenReady = wasPlaying
        }
    }

    private fun buildSource(request: PlayRequest, audioOnly: Boolean): MediaSource {
        val factory = getDataSourceFactory()

        val metadataBuilder = MediaMetadata.Builder()
            .setTitle(request.title)
            .setArtist(request.artist)
        request.artworkUrl?.let { metadataBuilder.setArtworkUri(Uri.parse(it)) }
        val metadata = metadataBuilder.build()

        // Canlı yayın: tek HLS manifesti hem sesi hem videoyu taşır, ayrık
        // parça yoktur. Sesli modda video parçasının seçilmesi
        // [applyAudioOnlyTrackSelection] ile engellenir.
        if (request.isLive) {
            return HlsMediaSource.Factory(factory).createMediaSource(
                MediaItem.Builder()
                    .setUri(request.audioUrl)
                    .setMediaMetadata(metadata)
                    .build()
            )
        }

        val videoUrl = request.videoUrl.takeUnless { audioOnly }

        val audioSource = ProgressiveMediaSource.Factory(factory).createMediaSource(
            MediaItem.Builder()
                .setUri(request.audioUrl)
                // Bildirimde gösterilecek meta veriyi tek bir kaynağa bağlıyoruz;
                // birleştirilmiş kaynakta video parçası bunu taşır.
                .setMediaMetadata(if (videoUrl == null) metadata else MediaMetadata.EMPTY)
                .build()
        )

        if (videoUrl == null) return audioSource

        // "Otomatik" kalitede video adresi tek bir dosya değil, tüm
        // çözünürlükleri listeleyen bir DASH manifestidir; çözünürlüğü
        // indirme hızına bakarak oynatıcı seçer.
        val videoSource = if (DashManifestBuilder.isManifest(videoUrl)) {
            dashSource(factory, videoUrl, metadata) ?: return audioSource
        } else {
            ProgressiveMediaSource.Factory(factory).createMediaSource(
                MediaItem.Builder().setUri(videoUrl).setMediaMetadata(metadata).build()
            )
        }

        // YouTube'un yüksek çözünürlüklü akışları video ve sesi ayrı verir;
        // ikisini aynı zaman çizgisinde birleştiriyoruz.
        return MergingMediaSource(
            /* adjustPeriodTimeOffsets= */ true,
            /* clipDurations= */ true,
            videoSource,
            audioSource
        )
    }

    /**
     * Manifest ağdan değil elimizden geldiği için çözümlenip doğrudan
     * kaynağa veriliyor; oynatıcı yalnızca içindeki video parçalarını indirir.
     *
     * Çözümleme başarısız olursa null döner ve çağıran taraf sese düşer —
     * kullanıcı hata ekranı yerine (görüntüsüz de olsa) devam eden bir
     * oynatma görür.
     */
    private fun dashSource(
        factory: DataSource.Factory,
        manifestUri: String,
        metadata: MediaMetadata
    ): MediaSource? = try {
        val manifest = DashManifestParser().parse(
            // Tüm adresler manifest içinde mutlak; bu taban adres yalnızca
            // çözümleyicinin istediği bir yer tutucu.
            Uri.parse("dash://otomatik"),
            java.io.ByteArrayInputStream(DashManifestBuilder.decode(manifestUri))
        )
        DashMediaSource.Factory(factory).createMediaSource(
            manifest,
            MediaItem.Builder()
                .setUri("dash://otomatik")
                .setMediaMetadata(metadata)
                .build()
        )
    } catch (e: Exception) {
        null
    }

    @Synchronized
    fun release() {
        playGeneration++ // ağ bekleyen bir geçiş, kapatılan oynatıcıyı diriltmesin
        audioFocus?.release()
        audioFocus = null
        loudness.release()
        exoPlayer?.release()
        exoPlayer = null
        currentRequest = null
    }

    /** Kullanıcı oynatmayı tamamen durdurduğunda odağı bırakır. */
    fun abandonAudioFocus() {
        audioFocus?.abandon()
    }

    /** Kullanıcı elle devam ettirdiğinde odağın bizde olduğundan emin ol. */
    fun requestAudioFocus(): Boolean = audioFocus?.request() ?: true

    fun isPlaying(): Boolean = exoPlayer?.playWhenReady == true

    /** Küçük penceredeki sistem düğmesi için: çalıyorsa duraklat, tersi. */
    fun togglePlayback() {
        val current = exoPlayer ?: return
        if (current.playWhenReady) {
            current.playWhenReady = false
        } else {
            userIntent()
            audioFocus?.request()
            current.playWhenReady = true
        }
    }
}
