package com.utkuhalis.akis

import com.utkuhalis.akis.extractor.ExtractionService
import com.utkuhalis.akis.player.PlaybackController
import com.utkuhalis.akis.player.PlayerPlatformViewFactory
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

    // Sonuçlar her zaman ana thread'e (Dispatchers.Main) dönerek result.success/error
    // çağrılıyor — MethodChannel.Result yalnızca platform thread'inden çağrılabilir.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var playbackController: PlaybackController? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        flutterEngine.platformViewsController.registry.registerViewFactory(
            PlaybackController.VIEW_TYPE,
            PlayerPlatformViewFactory()
        )

        playbackController = PlaybackController(
            context = applicationContext,
            methodChannel = MethodChannel(messenger, PlaybackController.METHOD_CHANNEL),
            eventChannel = EventChannel(messenger, PlaybackController.EVENT_CHANNEL)
        )

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
                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        result.error("EXTRACTION_ERROR", e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
    }

    override fun onDestroy() {
        scope.cancel()
        // Yalnızca kanal dinleyicileri bırakılır; player bilerek serbest
        // BIRAKILMAZ — aktivite kapansa da arka planda oynatma sürsün.
        playbackController?.dispose()
        playbackController = null
        super.onDestroy()
    }
}
