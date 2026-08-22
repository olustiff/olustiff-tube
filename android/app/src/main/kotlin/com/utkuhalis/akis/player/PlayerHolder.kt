package com.utkuhalis.akis.player

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.utkuhalis.akis.extractor.ExtractionService
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

    /** Kullanıcının seçtiği mod. Uygulamanın hiçbir yerinde otomatik değişmez. */
    @Volatile
    var audioOnlyMode: Boolean = false
        private set

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

    /** Otomatik geçiş sırasında yeni bir bitiş olayının araya girmesini önler. */
    @Volatile
    private var advancing = false

    @Synchronized
    fun getPlayer(context: Context): ExoPlayer {
        exoPlayer?.let { return it }
        val appContext = context.applicationContext
        return ExoPlayer.Builder(appContext).build().also { player ->
            exoPlayer = player
            // Otomatik geçiş NATIVE tarafta dinleniyor: ekran kapalıyken de
            // parça bitince sıradakine geçilmeli. Bu dinleyici Dart'ta olsaydı
            // Flutter motoru askıya alındığında hiç tetiklenmezdi.
            player.addListener(object : Player.Listener {
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
        val selection = StreamSelector.select(info, audioOnlyMode) ?: return
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
        applyAudioOnlyTrackSelection(player, request, audioOnly)
        player.setMediaSource(buildSource(request, audioOnly))
        player.prepare()
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
    fun setAudioOnly(context: Context, audioOnly: Boolean) {
        val request = currentRequest ?: return
        if (audioOnly == audioOnlyMode) return
        val player = getPlayer(context)
        val position = player.currentPosition
        val wasPlaying = player.playWhenReady
        audioOnlyMode = audioOnly
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

        val videoSource = ProgressiveMediaSource.Factory(factory).createMediaSource(
            MediaItem.Builder().setUri(videoUrl).setMediaMetadata(metadata).build()
        )

        // YouTube'un yüksek çözünürlüklü akışları video ve sesi ayrı verir;
        // ikisini aynı zaman çizgisinde birleştiriyoruz.
        return MergingMediaSource(
            /* adjustPeriodTimeOffsets= */ true,
            /* clipDurations= */ true,
            videoSource,
            audioSource
        )
    }

    @Synchronized
    fun release() {
        exoPlayer?.release()
        exoPlayer = null
        currentRequest = null
    }
}
