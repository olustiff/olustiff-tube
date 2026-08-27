package com.olustiff.app.player

import android.media.audiofx.LoudnessEnhancer
import android.util.Log

/**
 * Sesi YouTube seviyesine yaklaştırır.
 *
 * YouTube kendi uygulamasında her videonun ses seviyesi bilgisini (loudness)
 * okuyup sesi ona göre yükseltiyor. Biz ham akışı çaldığımız için ses belirgin
 * şekilde kısık kalıyordu — kullanıcının ölçümüyle, YouTube'da 20 kademede
 * alınan ses bu uygulamada ancak 50 kademede alınıyordu.
 *
 * NewPipeExtractor bu bilgiyi hiç sunmuyor (ne AudioStream'de ne itag
 * verisinde), bu yüzden telafi sabit bir kazançla yapılıyor. Android'in kendi
 * efekti kullanılıyor: örnekleri elle çarpmak tepe noktalarda sesi kırpardı,
 * bu efekt ise sıkıştırmayı kendi yönetiyor.
 */
class LoudnessBoost {

    private var enhancer: LoudnessEnhancer? = null

    /** Kazanç, milibel cinsinden (100 mB = 1 dB). */
    private var gainMillibels = DEFAULT_GAIN

    /** Oynatıcının ses oturumu değiştikçe efekt yeniden kurulur. */
    fun attach(audioSessionId: Int) {
        release()
        if (audioSessionId == 0) return
        enhancer = try {
            LoudnessEnhancer(audioSessionId).apply {
                setTargetGain(gainMillibels)
                enabled = gainMillibels > 0
            }
        } catch (e: Exception) {
            // Bazı cihazlarda bu efekt yok; ses kısık kalır ama oynatma sürer.
            Log.w(TAG, "Ses yükseltme kurulamadı", e)
            null
        }
    }

    /** Kazancı değiştirir (milibel). 0 = kapalı. */
    fun setGain(millibels: Int) {
        gainMillibels = millibels.coerceIn(0, MAX_GAIN)
        enhancer?.let {
            try {
                it.setTargetGain(gainMillibels)
                it.enabled = gainMillibels > 0
            } catch (e: Exception) {
                Log.w(TAG, "Ses kazancı uygulanamadı", e)
            }
        }
    }

    fun release() {
        try {
            enhancer?.release()
        } catch (_: Exception) {
            // Serbest bırakma hatası oynatmayı etkilemiyor.
        }
        enhancer = null
    }

    companion object {
        private const val TAG = "OlustiffLoudness"

        /** Varsayılan +9 dB: ölçülen fark bu civarda. */
        const val DEFAULT_GAIN = 900

        /** Üstü kırpma ve bozulma riski taşıyor. */
        const val MAX_GAIN = 1500
    }
}
