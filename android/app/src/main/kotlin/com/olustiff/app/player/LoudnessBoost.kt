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
 * verisinde; v0.26.5 jar'ında "loudness" diye bir alan yok), bu yüzden telafi
 * sabit bir kazançla yapılıyor.
 *
 * ## Kazancın neden ölçülü tutulduğu
 *
 * Android'in [LoudnessEnhancer]'ı sabit bir yükseltici DEĞİL: belgesinde
 * yazdığı gibi "platformun örnek aralığının dışına taşan sinyaller
 * SIKIŞTIRILIR". Yani efekt, kazancı taşıran her yerde devreye giren bir
 * kompresör gibi davranıyor.
 *
 * Müzik zaten yüksek seviyede masterlanıyor ve tepe noktaları tam ölçeğe çok
 * yakın. +9 dB ile sinyalin büyük kısmı taşıyor, kompresör sürekli çalışıyor
 * ve ses DUYULUR şekilde "bir sıkılıp bir açılıyor" (pumping) — gerçek
 * cihazda yaşandı. Varsayılan bu yüzden +4 dB'ye çekildi: kısıklığı belirgin
 * biçimde telafi ediyor ama efekti sürekli sıkıştırma bölgesine sokmuyor.
 *
 * Kullanıcı yine de kapatabiliyor ya da yükseltebiliyor (Ayarlar → Ses
 * yükseltme); bozulmayı duyan kişi ile kısıklıktan şikâyet eden kişi aynı
 * kişi olmayabilir.
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

        /**
         * Varsayılan +4 dB.
         *
         * Ölçülen kısıklık farkı +9 dB civarındaydı ve başta o seçilmişti; ama
         * o değerde efektin kendi sıkıştırması duyuluyordu (bkz. sınıf
         * belgesi). Sesin biraz kısık kalması, sesin nefes alıp vermesinden
         * iyi.
         */
        const val DEFAULT_GAIN = 400

        /** Üstü kırpma ve bozulma riski taşıyor. */
        const val MAX_GAIN = 1500
    }
}
