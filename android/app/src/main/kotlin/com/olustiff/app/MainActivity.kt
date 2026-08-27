package com.olustiff.app

import android.Manifest
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.speech.RecognizerIntent
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

                // Televizyonda kumandayla geziliyor: arayüz odak çerçevesi
                // gösterip dokunmaya özel hareketleri devre dışı bırakıyor.
                "isTelevision" -> result.success(isTelevision())

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

                // Sesli arama: kumandanın/telefonun mikrofonuyla arama.
                // Cihazda ses tanıma yoksa arayüz mikrofon düğmesini hiç
                // göstermesin diye önce sorulur.
                "isVoiceSearchAvailable" -> result.success(isVoiceSearchAvailable())

                "startVoiceSearch" -> startVoiceSearch(result)

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
                            "suggestions" -> {
                                val query = call.argument<String>("query").orEmpty()
                                result.success(ExtractionService.suggestions(query))
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

    private fun isTelevision(): Boolean {
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        // Bazı TV kutuları UiModeManager'ı doğru bildirmiyor; leanback
        // özelliği daha güvenilir bir işaret.
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    // ------------------------------------------------------------ sesli arama

    /**
     * Ses tanıma SİSTEMİN kendi ekranıyla yapılıyor.
     *
     * Bu yüzden uygulamanın RECORD_AUDIO iznine ihtiyacı YOK: mikrofonu açan
     * da izni soran da ses tanıma uygulaması. Kendi kaydımızı alsaydık izin
     * istemek ve reddedilme durumunu yönetmek gerekirdi.
     */
    private fun voiceSearchIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "tr-TR")
            .putExtra(RecognizerIntent.EXTRA_PROMPT, "Ne aramak istiyorsun?")

    private fun isVoiceSearchAvailable(): Boolean =
        runCatching {
            packageManager.queryIntentActivities(voiceSearchIntent(), 0).isNotEmpty()
        }.getOrDefault(false)

    /**
     * Ses tanıma ekranını açar. Sonuç [onActivityResult]'ta geldiği için
     * yanıt burada verilmez, [pendingVoiceResult]'ta bekletilir.
     */
    private fun startVoiceSearch(result: MethodChannel.Result) {
        // Bir MethodChannel.Result yalnızca BİR kez yanıtlanabilir: önceki
        // istek hâlâ bekliyorsa (kullanıcı hızlı hızlı bastıysa) boş
        // sonuçla kapatılır.
        pendingVoiceResult?.success(null)
        pendingVoiceResult = null
        try {
            startActivityForResult(voiceSearchIntent(), REQ_VOICE)
            pendingVoiceResult = result
        } catch (e: Exception) {
            // Ses tanıma yoksa uygulama çökmemeli; arayüz sessizce vazgeçer.
            result.success(null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_VOICE) return
        val pending = pendingVoiceResult ?: return
        pendingVoiceResult = null
        // Kullanıcı vazgeçtiyse ya da hiçbir şey anlaşılmadıysa null döner;
        // arayüz arama kutusunu olduğu gibi bırakır.
        val spoken = if (resultCode == RESULT_OK) {
            data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull()
                ?.takeIf { it.isNotBlank() }
        } else {
            null
        }
        pending.success(spoken)
    }

    private var pendingVoiceResult: MethodChannel.Result? = null

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
            )
        ) {
            return false
        }
        return enterPictureInPictureMode(pipParams())
    }

    /**
     * Küçük pencerenin ayarları.
     *
     * Oynat/duraklat düğmesi buradan, SİSTEM düğmesi olarak veriliyor:
     * uygulamanın kendi kontrolleri küçük pencerede okunaksız kalıyor ve
     * pencerede yalnızca görüntü olması gerekiyor.
     */
    private fun pipParams(): PictureInPictureParams {
        val ratio = PlayerHolder.videoAspectRatio
        // Android, en/boy oranını 1:2.39 ile 2.39:1 arasında ister.
        val clamped = ratio.coerceIn(0.42, 2.39)
        return PictureInPictureParams.Builder()
            .setAspectRatio(Rational((clamped * 1000).toInt(), 1000))
            .setActions(listOf(playPauseAction()))
            .build()
    }

    private fun playPauseAction(): RemoteAction {
        val playing = PlayerHolder.isPlaying()
        val icon = Icon.createWithResource(
            this,
            if (playing) R.drawable.ic_pip_pause else R.drawable.ic_pip_play
        )
        val label = if (playing) "Duraklat" else "Oynat"
        val intent = PendingIntent.getBroadcast(
            this,
            REQUEST_PIP_TOGGLE,
            Intent(ACTION_PIP_TOGGLE).setPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return RemoteAction(icon, label, label, intent)
    }

    /** Küçük penceredeki düğmeye basıldığında oynatmayı çevirir. */
    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_PIP_TOGGLE) return
            PlayerHolder.togglePlayback()
            // Düğmenin ikonu duruma göre değişmeli.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setPictureInPictureParams(pipParams())
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // Arayüz, küçük pencerede kontrolleri gizleyebilsin diye haberdar edilir.
        pipChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)

        if (isInPictureInPictureMode) {
            registerPipReceiver()
        } else {
            unregisterPipReceiver()
        }
    }

    private var pipReceiverRegistered = false

    private fun registerPipReceiver() {
        if (pipReceiverRegistered) return
        val filter = IntentFilter(ACTION_PIP_TOGGLE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipActionReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(pipActionReceiver, filter)
        }
        pipReceiverRegistered = true
    }

    private fun unregisterPipReceiver() {
        if (!pipReceiverRegistered) return
        runCatching { unregisterReceiver(pipActionReceiver) }
        pipReceiverRegistered = false
    }

    private var pipChannel: MethodChannel? = null

    private companion object {
        const val ACTION_PIP_TOGGLE = "com.olustiff.app.PIP_TOGGLE"
        const val REQUEST_PIP_TOGGLE = 1001
    }

    private val REQ_BLUETOOTH = 4711
    private val REQ_STORAGE = 4712
    private val REQ_VOICE = 4713

    override fun onDestroy() {
        scope.cancel()
        // Ses tanıma ekranı açıkken uygulama kapanırsa Dart tarafı sonsuza
        // kadar beklemesin.
        pendingVoiceResult?.success(null)
        pendingVoiceResult = null
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
