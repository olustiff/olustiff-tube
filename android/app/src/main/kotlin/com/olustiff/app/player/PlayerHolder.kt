package com.olustiff.app.player

import android.content.Context
import android.net.Uri
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.dash.manifest.DashManifestParser
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.olustiff.app.extractor.ExtractionService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

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
        return ExoPlayer.Builder(appContext)
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
                    if (playbackState != Player.STATE_ENDED) return
                    if (!PlaybackQueue.autoplay || advancing) return
                    advancing = true
                    scope.launch {
                        try {
                            playNext(appContext)
                        } finally {
                            advancing = false
                        }
                    }
                }
            })
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

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

    suspend fun playNext(context: Context) {
        val item = PlaybackQueue.advance() ?: return
        playQueueItem(context, item)
    }

    suspend fun playPrevious(context: Context) {
        val item = PlaybackQueue.back() ?: return
        playQueueItem(context, item)
    }

    suspend fun playAt(context: Context, index: Int) {
        val item = PlaybackQueue.jumpTo(index) ?: return
        playQueueItem(context, item)
    }

    @Synchronized
    private fun getDataSourceFactory(): DataSource.Factory {
        return dataSourceFactory ?: OkHttpDataSource.Factory(OkHttpClient.Builder().build())
            .setUserAgent(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            )
            .also { dataSourceFactory = it }
    }

    /**
     * Yeni bir medya yükler. [audioOnly] true ise video parçası hiç
     * indirilmez — bu, "arka planda müzik dinleme" modunda hem veri hem pil
     * tasarrufu sağlar ve videoya geçişi yapısal olarak imkansız kılar.
     */
    fun play(context: Context, request: PlayRequest, audioOnly: Boolean) {
        val player = getPlayer(context)
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
        player.playWhenReady = true
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
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, request.isLive && audioOnly)
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
        player.playWhenReady = true
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
        audioFocus?.abandon()
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
            audioFocus?.request()
            current.playWhenReady = true
        }
    }
}
