package com.olustiff.app.player

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.media3.exoplayer.ExoPlayer

/**
 * Ses odağını kendimiz yönetiyoruz.
 *
 * Media3'ün otomatik yönetimi (`handleAudioFocus = true`) telefon/VoIP
 * aramalarında çoğu cihazda oynatmayı DURAKLATMIYOR, yalnızca sesi kısıyor
 * (ducking). Kullanıcı arama boyunca müziğin durmasını bekliyor; bu yüzden
 * odak olaylarını burada karşılıyoruz.
 *
 * ## Kısmak mı durdurmak mı
 *
 * Bir zamanlar HER kayıp türünde duraklatılıyordu. Bu, aramayı doğru çözüyor
 * ama kısa bir bildirim için de müziği kesip geri başlatıyordu — kullanıcı
 * için "bir şey bozuldu" hissi veren, gereksiz sert bir davranış.
 *
 * Artık ayrım şöyle:
 * - **Kısa, kısılabilir kayıp** (bildirim, navigasyon anonsu): ses
 *   [DUCK_VOLUME] seviyesine iner, oynatma SÜRER, olay bitince geri açılır.
 * - **Geçici ama kısılamaz kayıp** (arama): duraklatılır, sonra kaldığı
 *   yerden devam eder.
 * - **Kalıcı kayıp** (başka uygulama müzik açtı): duraklatılır, geri dönülmez.
 *
 * Tek başına odak türüne bakmak YETMİYOR: şikâyetin kaynağı olan cihazlarda
 * arama da "kısılabilir" olarak bildiriliyor. Bu yüzden kısmadan önce
 * [CallState] ile gerçekten konuşulup konuşulmadığı soruluyor; ayrıca kısık
 * çalarken [durationWatch] bu soruyu tekrarlıyor, çünkü telefon çalarken
 * gelen kısma isteği ile aramanın yanıtlanması arasında saniyeler var ve o
 * anda ikinci bir odak olayı gelmiyor.
 */
class AudioFocusHandler(context: Context, private val player: ExoPlayer) {

    private val appContext = context.applicationContext

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** Şu an sesi kısılmış hâlde mi çalıyoruz. */
    private var ducked = false

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Kısıkken "arama başladı mı" diye tekrar tekrar bakan iş.
     *
     * Gerekli çünkü telefon ÇALARKEN gelen kısma isteğinden sonra kullanıcı
     * aramayı yanıtladığında sistem yeni bir odak olayı göndermiyor; yalnızca
     * ses kipi değişiyor. Bakılmazsa müzik arama boyunca kısık çalmaya devam
     * ederdi.
     */
    private val durationWatch = object : Runnable {
        override fun run() {
            if (!ducked) return
            if (CallState.isInCall(appContext)) {
                Log.d(TAG, "Kısıkken arama başladı, duraklatıldı")
                pauseFromDuck()
                return
            }
            handler.postDelayed(this, CALL_CHECK_INTERVAL_MS)
        }
    }

    /**
     * Odak GEÇİCİ kaybedildiğinde çalıyor muyduk? Arama bitince yalnızca
     * kullanıcının kendi duraklattığı bir şeyi kendiliğinden başlatmayalım.
     */
    private var resumeOnFocusGain = false

    private var hasFocus = false

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            // Kalıcı kayıp (başka uygulama müzik açtı): duraklat, geri dönme.
            AudioManager.AUDIOFOCUS_LOSS -> {
                stopDuckWatch()
                player.volume = 1f
                resumeOnFocusGain = false
                hasFocus = false
                player.playWhenReady = false
                Log.d(TAG, "Odak kalıcı kaybedildi, duraklatıldı")
            }

            // Kısılabilir kayıp: bildirim sesi, navigasyon anonsu gibi kısa
            // araya girmeler. Müziği kesmek yerine sesi indiriyoruz.
            //
            // Ama önce gerçekten konuşuluyor mu diye bakılıyor: şikâyetin
            // kaynağı olan cihazlarda arama da bu türle bildiriliyor ve
            // kısarak sürdürmek yanlış olurdu.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                if (CallState.isInCall(appContext)) {
                    resumeOnFocusGain = player.playWhenReady
                    player.playWhenReady = false
                    Log.d(TAG, "Arama sürüyor, kısmak yerine duraklatıldı")
                } else if (player.playWhenReady) {
                    ducked = true
                    player.volume = DUCK_VOLUME
                    handler.postDelayed(durationWatch, CALL_CHECK_INTERVAL_MS)
                    Log.d(TAG, "Kısa kesinti, ses kısıldı")
                }
            }

            // Arama geldi: duraklat, sonra kaldığı yerden devam et.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                stopDuckWatch()
                resumeOnFocusGain = player.playWhenReady
                player.playWhenReady = false
                Log.d(TAG, "Odak geçici kaybedildi, duraklatıldı")
            }

            AudioManager.AUDIOFOCUS_GAIN -> {
                hasFocus = true
                // Kısılmış hâlde çalıyorduysak sesi geri açmak yeterli;
                // oynatma hiç kesilmedi, tazelenecek bir ses yolu yok.
                if (ducked) {
                    stopDuckWatch()
                    player.volume = 1f
                    Log.d(TAG, "Kesinti bitti, ses geri açıldı")
                }
                if (resumeOnFocusGain && PlayerHolder.outputLost) {
                    // Bu arada Bluetooth/kulaklık koptu: odak dönüşü sesi
                    // HOPARLÖRDEN başlatırdı (bkz. PlayerHolder.outputLost).
                    resumeOnFocusGain = false
                    Log.d(TAG, "Odak geri geldi ama ses çıkışı koptu; başlatılmadı")
                }
                if (resumeOnFocusGain) {
                    resumeOnFocusGain = false

                    // Arama sırasında sistem ses yolunu kapatıyor; öylece
                    // devam ettirilirse oynatma ilerler ama SES GELMEZ.
                    // Konuma yeniden gitmek çözücüyü ve ses çıkışını
                    // tazeliyor. Ses seviyesi de kısılmış olabilir.
                    player.volume = 1f
                    if (player.isCurrentMediaItemLive) {
                        // Canlı yayında eski konuma dönmek akışın kenarından
                        // koparıyor; doğrusu canlı kenara geri dönmek.
                        player.seekToDefaultPosition()
                    } else if (player.isCurrentMediaItemSeekable) {
                        player.seekTo(player.currentPosition)
                    }

                    player.playWhenReady = true
                    Log.d(TAG, "Odak geri geldi, ses çıkışı tazelendi")
                }
            }
        }
    }

    private val request: AudioFocusRequest? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    PlatformAudioAttributes.Builder()
                        .setUsage(PlatformAudioAttributes.USAGE_MEDIA)
                        .setContentType(PlatformAudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                // Kısmayı sisteme BIRAKMIYORUZ. `false` verilseydi sistem
                // sesi kendi kısardı ve bize haber bile vermezdi; o zaman
                // araması "kısılabilir" diye bildirilen cihazlarda müziği
                // duraklatma şansımız hiç olmazdı. `true` ile olay bize
                // geliyor ve kısmakla durdurmak arasındaki kararı biz
                // veriyoruz (bkz. sınıf belgesi).
                .setWillPauseWhenDucked(true)
                // Odak meşgulken (süren arama) istek reddedilmek yerine
                // BEKLETİLİR: kullanıcı arama sırasında oynat'a bastığında
                // hiçbir şey olmuyordu. Sistem odak serbest kalınca GAIN
                // gönderiyor, oynatma o an başlıyor.
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(listener)
                .build()
        } else {
            null
        }

    /**
     * Oynatma başlarken çağrılır.
     *
     * Odak hemen alınabildiyse true döner. Arama gibi bir sebeple meşgulse
     * false döner — ama çağıran taraf oynatmayı yine de başlatır: kullanıcı
     * bilerek istediyse odağın reddi onu engellememeli.
     */
    fun request(): Boolean {
        if (hasFocus) return true
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioManager.requestAudioFocus(request!!)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }

        hasFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!hasFocus) {
            // Odak şu an başkasında (süren arama). Oynatma yine de başlıyor —
            // kullanıcı bilerek istedi. Odak serbest kalınca sistem GAIN
            // gönderiyor ve ses yolu orada tazeleniyor.
            resumeOnFocusGain = true
            Log.d(TAG, "Odak alınamadı (sonuç=$result), oynatma yine de sürüyor")
        }
        return hasFocus
    }

    /** Kısık çalmayı duraklatmaya çevirir (arama başladığında). */
    private fun pauseFromDuck() {
        stopDuckWatch()
        player.volume = 1f
        resumeOnFocusGain = player.playWhenReady
        player.playWhenReady = false
    }

    private fun stopDuckWatch() {
        ducked = false
        handler.removeCallbacks(durationWatch)
    }

    /**
     * Ses çıkışının (Bluetooth/kulaklık) kopmasını OYNATMA DURUMUNDAN BAĞIMSIZ
     * dinler.
     *
     * Oynatıcının kendi "kulaklık çıktı" koruması yalnızca çalarken devrede.
     * Araba Bluetooth'u koparken önce odağı alıp oynatmayı durdurduğu için
     * kopma anında oynatıcı zaten duruyordu, koruma hiç tetiklenmiyordu ve
     * odak dönünce müzik hoparlörden başlıyordu. İki kaynak birden dinleniyor
     * çünkü cihazlar arasında hangisinin geleceği tutarlı değil.
     */
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            onOutputLost("ses çıkışı hoparlöre döndü")
        }
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            val lost = removedDevices.firstOrNull { it.isSink && it.type in PERSONAL_OUTPUTS }
                ?: return
            onOutputLost("${lost.productName} ayrıldı")
        }
    }

    private fun onOutputLost(reason: String) {
        stopDuckWatch()
        player.volume = 1f
        resumeOnFocusGain = false
        PlayerHolder.onOutputLost(reason)
    }

    init {
        ContextCompat.registerReceiver(
            appContext,
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        audioManager.registerAudioDeviceCallback(deviceCallback, handler)
    }

    /** Oynatıcı kapatılırken dinleyicileri bırakır. */
    fun release() {
        abandon()
        runCatching { appContext.unregisterReceiver(noisyReceiver) }
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
    }

    /** Oynatma tamamen bittiğinde odağı bırakır. */
    fun abandon() {
        stopDuckWatch()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            request?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(listener)
        }
        hasFocus = false
        resumeOnFocusGain = false
    }

    private companion object {
        const val TAG = "OlustiffAudioFocus"

        /** Kopunca sesin hoparlöre düşeceği kişisel çıkışlar. */
        val PERSONAL_OUTPUTS = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            26, // TYPE_BLE_HEADSET (API 31)
            27, // TYPE_BLE_SPEAKER (API 31)
        )

        /**
         * Kısma sırasındaki ses seviyesi.
         *
         * Android'in kendi kısması yaklaşık -14 dB; 0.2 onunla aynı hizada.
         * Daha yüksek bırakmak bildirimi bastırıyor, daha düşük bırakmak
         * müziği tamamen susmuş gibi gösteriyor.
         */
        const val DUCK_VOLUME = 0.2f

        /** Kısıkken aramanın başlayıp başlamadığına bakma aralığı. */
        const val CALL_CHECK_INTERVAL_MS = 700L
    }
}
