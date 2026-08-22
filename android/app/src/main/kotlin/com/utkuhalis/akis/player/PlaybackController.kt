package com.utkuhalis.akis.player

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
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
    eventChannel: EventChannel
) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

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

            // Kullanıcının elle mod değiştirmesi — konumu koruyarak.
            "setAudioOnly" -> {
                PlayerHolder.setAudioOnly(context, call.argument<Boolean>("audioOnly") ?: false)
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
                "speed" to player.playbackParameters.speed
            )
        )
    }

    fun dispose() {
        mainHandler.removeCallbacks(positionTicker)
        eventSink = null
    }

    companion object {
        const val METHOD_CHANNEL = "akis/player"
        const val EVENT_CHANNEL = "akis/player_events"
        const val VIEW_TYPE = "akis/player_view"
        private const val POSITION_UPDATE_INTERVAL_MS = 500L
    }
}
