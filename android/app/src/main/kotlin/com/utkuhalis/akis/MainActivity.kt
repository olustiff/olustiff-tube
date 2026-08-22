package com.utkuhalis.akis

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import com.utkuhalis.akis.extractor.ExtractionService
import com.utkuhalis.akis.player.PlayerHolder
import com.utkuhalis.akis.player.PlaybackController
import com.utkuhalis.akis.player.VideoTextureBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {

    private val extractorChannelName = "akis/extractor"
    private val uiChannelName = "akis/ui"

    // Sonuçlar her zaman ana thread'e (Dispatchers.Main) dönerek result.success/error
    // çağrılıyor — MethodChannel.Result yalnızca platform thread'inden çağrılabilir.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var playbackController: PlaybackController? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Video, PlatformView yerine Flutter'ın doku katmanına render ediliyor
        // (bkz. VideoTextureBridge) — gömülü PlayerView bazı gerçek cihazlarda
        // siyah kalıyordu.
        playbackController = PlaybackController(
            context = applicationContext,
            methodChannel = MethodChannel(messenger, PlaybackController.METHOD_CHANNEL),
            eventChannel = EventChannel(messenger, PlaybackController.EVENT_CHANNEL),
            textureBridge = VideoTextureBridge(flutterEngine.renderer)
        )

        // Ekranı açık tutma ve resim-içinde-resim yalnızca aktivite üzerinden
        // yapılabildiği için ayrı bir kanalda tutuluyor.
        val uiChannel = MethodChannel(messenger, uiChannelName)
        pipChannel = uiChannel
        uiChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> {
                    val keepOn = call.argument<Boolean>("enabled") ?: false
                    if (keepOn) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }

                "enterPictureInPicture" -> result.success(enterPip())

                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, extractorChannelName)
            .setMethodCallHandler { call, result ->
                scope.launch {
                    try {
                        when (call.method) {
                            "search" -> {
                                val query = call.argument<String>("query").orEmpty()
                                result.success(ExtractionService.search(query))
                            }
                            "trending" -> {
                                result.success(ExtractionService.trending())
                            }
                            "videoDetails" -> {
                                val videoId = call.argument<String>("videoId").orEmpty()
                                result.success(ExtractionService.videoDetails(videoId))
                            }
                            "loadMore" -> {
                                val kind = call.argument<String>("kind").orEmpty()
                                result.success(ExtractionService.loadMore(kind))
                            }
                            "playlist" -> {
                                val url = call.argument<String>("url").orEmpty()
                                result.success(ExtractionService.playlist(url))
                            }
                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        result.error("EXTRACTION_ERROR", e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
    }

    /**
     * Videoyu küçük pencerede sürdürür. Desteklenmeyen cihazlarda sessizce
     * false döner; arayüz butonu buna göre gizler.
     */
    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
            )
        ) {
            return false
        }
        val ratio = PlayerHolder.videoAspectRatio
        // Android, en/boy oranını 1:2.39 ile 2.39:1 arasında ister.
        val clamped = ratio.coerceIn(0.42, 2.39)
        val params = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((clamped * 1000).toInt(), 1000))
            .build()
        return enterPictureInPictureMode(params)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // Arayüz, küçük pencerede kontrolleri gizleyebilsin diye haberdar edilir.
        pipChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    private var pipChannel: MethodChannel? = null

    override fun onDestroy() {
        scope.cancel()
        // Yalnızca kanal dinleyicileri bırakılır; player bilerek serbest
        // BIRAKILMAZ — aktivite kapansa da arka planda oynatma sürsün.
        playbackController?.dispose()
        playbackController = null
        super.onDestroy()
    }
}
