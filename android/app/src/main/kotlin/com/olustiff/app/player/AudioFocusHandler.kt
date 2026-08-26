package com.olustiff.app.player

import android.content.Context
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log
import androidx.media3.exoplayer.ExoPlayer

/**
 * Ses odağını kendimiz yönetiyoruz.
 *
 * Media3'ün otomatik yönetimi (`handleAudioFocus = true`) telefon/VoIP
 * aramalarında çoğu cihazda oynatmayı DURAKLATMIYOR, yalnızca sesi kısıyor
 * (ducking). Kullanıcı arama boyunca müziğin durmasını, arama bitince kaldığı
 * yerden devam etmesini bekliyor; bu yüzden odak olaylarını burada karşılayıp
 * her kayıp türünde duraklatıyoruz.
 */
class AudioFocusHandler(context: Context, private val player: ExoPlayer) {

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

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
                resumeOnFocusGain = false
                hasFocus = false
                player.playWhenReady = false
                Log.d(TAG, "Odak kalıcı kaybedildi, duraklatıldı")
            }

            // Arama geldi ya da kısa bir bildirim: duraklat, sonra devam et.
            // "CAN_DUCK" da duraklatılıyor: kullanıcı arama sırasında müziğin
            // kısılmasını değil susmasını istiyor.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                resumeOnFocusGain = player.playWhenReady
                player.playWhenReady = false
                Log.d(TAG, "Odak geçici kaybedildi, duraklatıldı")
            }

            AudioManager.AUDIOFOCUS_GAIN -> {
                hasFocus = true
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
                // Sesi kısarak sürdürmeyi kabul etmiyoruz; duraklatmak
                // istediğimiz için olayı kendimiz karşılıyoruz.
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

    /** Oynatma tamamen bittiğinde odağı bırakır. */
    fun abandon() {
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
    }
}
