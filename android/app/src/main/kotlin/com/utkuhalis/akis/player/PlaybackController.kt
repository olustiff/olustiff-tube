package com.utkuhalis.akis.player

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter oynatıcı arayüzünün native karşılığı.
 *
 * Kontroller [PlayerHolder]'daki ortak ExoPlayer üzerinde çalışır; durum
 * güncellemeleri (konum, süre, oynuyor mu, tamponlanıyor mu, mod) bir
 * EventChannel ile Flutter'a akar.
 */
class PlaybackController(
    private val context: Context,
    methodChannel: MethodChannel,
    eventChannel: EventChannel,
    private val textureBridge: VideoTextureBridge
) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** Konum ilerlemesini düzenli aralıkla Flutter'a bildiren tekrarlayan görev. */
    private val positionTicker = object : Runnable {
        override fun run() {
            emitState()
            mainHandler.postDelayed(this, POSITION_UPDATE_INTERVAL_MS)
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) = emitState()
        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = emitState()
        override fun onIsPlayingChanged(isPlaying: Boolean) = emitState()

        override fun onPlayerError(error: PlaybackException) {
            eventSink?.error("PLAYBACK_ERROR", error.message, error.errorCodeName)
        }
    }

    init {
        methodChannel.setMethodCallHandler { call, result -> handleMethod(call, result) }

        // Native tarafta kuyruk ilerlediğinde (ör. parça bitti) arayüz açıksa
        // hemen güncellensin.
        PlayerHolder.onQueueAdvanced = { mainHandler.post { emitState() } }

        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                player().addListener(playerListener)
                mainHandler.post(positionTicker)
                emitState()
            }

            override fun onCancel(arguments: Any?) {
                mainHandler.removeCallbacks(positionTicker)
                player().removeListener(playerListener)
                eventSink = null
            }
        })
    }

    private fun player() = PlayerHolder.getPlayer(context)

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                val audioUrl = call.argument<String>("audioUrl")
                if (audioUrl.isNullOrBlank()) {
                    result.error("BAD_ARGS", "audioUrl zorunlu", null)
                    return
                }
                // Servisi normal (foreground olmayan) şekilde başlatıyoruz.
                // startForegroundService KULLANILMAZ: Media3 bildirimi ancak
                // oynatma fiilen başladığında oluşturur ve foreground'a o an
                // kendisi geçer; erken çağırmak 5 saniyelik startForeground
                // süresini kaçırıp uygulamayı çökertir.
                context.startService(Intent(context, PlaybackService::class.java))
                PlayerHolder.play(
                    context = context,
                    request = PlayerHolder.PlayRequest(
                        videoUrl = call.argument<String>("videoUrl"),
                        audioUrl = audioUrl,
                        title = call.argument<String>("title") ?: "",
                        artist = call.argument<String>("artist"),
                        artworkUrl = call.argument<String>("artworkUrl"),
                        isLive = call.argument<Boolean>("isLive") ?: false
                    ),
                    audioOnly = call.argument<Boolean>("audioOnly") ?: false
                )
                result.success(null)
            }

            // Video ekranı açıldığında dokuyu bağlar ve id'sini döner;
            // Flutter bu id ile `Texture` widget'ını çizer.
            "attachVideoTexture" -> result.success(textureBridge.attach())

            // Video ekranı kapandığında yalnızca görüntü ayrılır; ses sürer.
            "detachVideoTexture" -> {
                textureBridge.detach()
                result.success(null)
            }

            // İndirilmiş bir dosyayı oynatır. Ağ yok, kuyruk yok — tek dosya.
            "playLocal" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("BAD_ARGS", "path zorunlu", null)
                    return
                }
                context.startService(Intent(context, PlaybackService::class.java))
                PlaybackQueue.clear()
                PlayerHolder.playLocal(
                    context = context,
                    path = path,
                    title = call.argument<String>("title") ?: "",
                    artist = call.argument<String>("artist"),
                    audioOnly = call.argument<Boolean>("audioOnly") ?: false
                )
                result.success(null)
            }

            // Kuyruğu native tarafa yükler. Otomatik geçiş burada yaşadığı için
            // ekran kapalıyken de sıradakine geçilir.
            "setQueue" -> {
                @Suppress("UNCHECKED_CAST")
                val raw = call.argument<List<Map<String, Any?>>>("items").orEmpty()
                PlaybackQueue.set(
                    raw.map {
                        PlaybackQueue.Item(
                            videoId = it["videoId"] as? String ?: "",
                            title = it["title"] as? String ?: "",
                            uploaderName = it["uploaderName"] as? String,
                            thumbnailUrl = it["thumbnailUrl"] as? String
                        )
                    }.filter { it.videoId.isNotEmpty() },
                    startIndex = (call.argument<Number>("index") ?: -1).toInt()
                )
                result.success(null)
            }

            "setRepeatMode" -> {
                val mode = call.argument<String>("mode") ?: "off"
                PlaybackQueue.setRepeatMode(
                    when (mode) {
                        "one" -> PlaybackQueue.RepeatMode.ONE
                        "all" -> PlaybackQueue.RepeatMode.ALL
                        else -> PlaybackQueue.RepeatMode.OFF
                    }
                )
                emitState()
                result.success(null)
            }

            "setShuffle" -> {
                PlaybackQueue.setShuffle(call.argument<Boolean>("enabled") ?: false)
                emitState()
                result.success(null)
            }

            "setAutoplay" -> {
                PlaybackQueue.setAutoplayEnabled(call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }

            "next" -> {
                scope.launch {
                    PlayerHolder.playNext(context)
                    result.success(null)
                }
            }

            "previous" -> {
                scope.launch {
                    PlayerHolder.playPrevious(context)
                    result.success(null)
                }
            }

            "playQueueIndex" -> {
                val index = (call.argument<Number>("index") ?: 0).toInt()
                scope.launch {
                    PlayerHolder.playAt(context, index)
                    result.success(null)
                }
            }

            // Kullanıcının elle mod değiştirmesi — konumu koruyarak.
            "setAudioOnly" -> {
                PlayerHolder.setAudioOnly(
                    context = context,
                    audioOnly = call.argument<Boolean>("audioOnly") ?: false,
                    videoUrl = call.argument<String>("videoUrl"),
                    audioUrl = call.argument<String>("audioUrl")
                )
                emitState()
                result.success(null)
            }

            // Kalite değişimi: kaynaklar değişir, konum ve mod korunur.
            "replaceSources" -> {
                PlayerHolder.replaceSources(
                    context = context,
                    videoUrl = call.argument<String>("videoUrl"),
                    audioUrl = call.argument<String>("audioUrl")
                )
                emitState()
                result.success(null)
            }

            "resume" -> {
                player().playWhenReady = true
                result.success(null)
            }

            "pause" -> {
                player().playWhenReady = false
                result.success(null)
            }

            "seekTo" -> {
                val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                player().seekTo(positionMs)
                emitState()
                result.success(null)
            }

            "setSpeed" -> {
                val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                player().setPlaybackSpeed(speed)
                result.success(null)
            }

            "stop" -> {
                player().stop()
                player().clearMediaItems()
                context.stopService(Intent(context, PlaybackService::class.java))
                emitState()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun emitState() {
        val sink = eventSink ?: return
        val player = player()
        sink.success(
            mapOf(
                "positionMs" to player.currentPosition,
                "durationMs" to player.duration.takeIf { it > 0 },
                "bufferedPositionMs" to player.bufferedPosition,
                "isPlaying" to player.isPlaying,
                "playWhenReady" to player.playWhenReady,
                "isBuffering" to (player.playbackState == Player.STATE_BUFFERING),
                "isEnded" to (player.playbackState == Player.STATE_ENDED),
                "audioOnly" to PlayerHolder.audioOnlyMode,
                "speed" to player.playbackParameters.speed,
                "queueIndex" to PlaybackQueue.index,
                "queueSize" to PlaybackQueue.size,
                "autoplay" to PlaybackQueue.autoplay,
                "repeatMode" to PlaybackQueue.repeatMode.name.lowercase(),
                "shuffle" to PlaybackQueue.shuffle,
                "qualityLabel" to PlayerHolder.currentQualityLabel,
                "currentVideoId" to PlaybackQueue.current()?.videoId,
                "videoWidth" to player.videoSize.width,
                "videoHeight" to player.videoSize.height
            )
        )
    }

    fun dispose() {
        mainHandler.removeCallbacks(positionTicker)
        scope.cancel()
        textureBridge.detach()
        PlayerHolder.onQueueAdvanced = null
        eventSink = null
    }

    companion object {
        const val METHOD_CHANNEL = "akis/player"
        const val EVENT_CHANNEL = "akis/player_events"
        private const val POSITION_UPDATE_INTERVAL_MS = 500L
    }
}
