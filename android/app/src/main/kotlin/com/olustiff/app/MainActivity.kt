package com.olustiff.app

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import com.olustiff.app.download.DownloadController
import com.olustiff.app.update.UpdateController
import com.olustiff.app.extractor.ExtractionService
import com.olustiff.app.player.PlayerHolder
import com.olustiff.app.player.PlaybackController
import com.olustiff.app.player.VideoTextureBridge
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

    private val extractorChannelName = "olustiff/extractor"
    private val uiChannelName = "olustiff/ui"

    // Sonuçlar her zaman ana thread'e (Dispatchers.Main) dönerek result.success/error
    // çağrılıyor — MethodChannel.Result yalnızca platform thread'inden çağrılabilir.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var playbackController: PlaybackController? = null
    private var downloadController: DownloadController? = null
    private var updateController: UpdateController? = null

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

        downloadController = DownloadController(
            context = applicationContext,
            channel = MethodChannel(messenger, DownloadController.CHANNEL),
            progressChannel =
                EventChannel(messenger, DownloadController.PROGRESS_CHANNEL)
        )
        // Android 9 ve öncesinde indirmeler ortak Müzik klasörüne klasik dosya
        // yazmayla gidiyor ve bu izin ister. İzin AÇILIŞTA değil, ilk indirme
        // denendiğinde sorulur — kullanıcı neden sorulduğunu görsün.
        downloadController?.onRequestStoragePermission = {
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQ_STORAGE
            )
        }

        updateController = UpdateController(
            context = applicationContext,
            channel = MethodChannel(messenger, UpdateController.CHANNEL),
            progressChannel =
                EventChannel(messenger, UpdateController.PROGRESS_CHANNEL)
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

                // Bluetooth otomatik çalma, arka planda servis başlatmayı
                // gerektiriyor; bu da yalnızca pil optimizasyonundan muaf
                // uygulamalara izinli.
                // Android 12+ bu izni çalışma anında ister. İzin olmadan
                // bluetooth bağlantı yayınları uygulamaya HİÇ ulaşmaz.
                "hasBluetoothPermission" -> result.success(hasBluetoothPermission())

                "requestBluetoothPermission" -> {
                    if (hasBluetoothPermission()) {
                        result.success(true)
                    } else {
                        requestPermissions(
                            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                            REQ_BLUETOOTH
                        )
                        result.success(false)
                    }
                }

                "isBatteryOptimizationIgnored" -> {
                    val power = getSystemService(PowerManager::class.java)
                    result.success(
                        power?.isIgnoringBatteryOptimizations(packageName) ?: false
                    )
                }

                "requestIgnoreBatteryOptimization" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        // Bazı üreticiler bu ekranı kapatır; genel listeye düş.
                        startActivity(
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        )
                        result.success(false)
                    }
                }

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
    private fun hasBluetoothPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED

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

    private val REQ_BLUETOOTH = 4711
    private val REQ_STORAGE = 4712

    override fun onDestroy() {
        scope.cancel()
        // Yalnızca kanal dinleyicileri bırakılır; player bilerek serbest
        // BIRAKILMAZ — aktivite kapansa da arka planda oynatma sürsün.
        playbackController?.dispose()
        playbackController = null
        downloadController?.dispose()
        downloadController = null
        updateController?.dispose()
        updateController = null
        super.onDestroy()
    }
}
