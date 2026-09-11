package com.olustiff.app.player

import android.content.Context
import android.media.AudioManager

/**
 * "Şu an telefonda konuşuluyor mu?" sorusunun tek cevap yeri.
 *
 * İki ayrı yerde gerekiyor ve ikisinde de yanlış cevap kullanıcıyı rahatsız
 * ediyordu:
 * - Ses odağı kaybında müziği KISMAK mı yoksa DURDURMAK mı gerektiği
 *   (bildirim geldiyse kısmak, arama geldiyse durdurmak),
 * - Bluetooth kulaklık bağlanınca otomatik çalmanın başlayıp başlamayacağı —
 *   kullanıcı konuşurken kulaklık bağladığında müzik başlıyordu.
 *
 * Neden [AudioManager.getMode] ve telefon durumu API'si değil: `TelephonyManager`
 * ile arama durumunu okumak Android 12'den beri `READ_PHONE_STATE` izni
 * istiyor. Ses kipi izinsiz okunuyor, üstelik doğru soruyu cevaplıyor —
 * bizi ilgilendiren şey aramanın kendisi değil, ses yolunun konuşmaya ayrılmış
 * olması. VoIP aramaları (WhatsApp, Telegram) da bu yüzden kapsama giriyor;
 * telefon durumu API'si onları hiç görmezdi.
 */
object CallState {

    /** Hücresel ya da VoIP bir görüşme sürüyor mu. */
    fun isInCall(context: Context): Boolean = when (mode(context)) {
        AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION -> true
        else -> false
    }

    /**
     * Ses yolu müzik için uygun mu.
     *
     * [isInCall]'dan daha geniş: telefon ÇALIYORken de false döner. Otomatik
     * çalmayı başlatmadan önce bakılan soru bu — telefon çalarken kulaklık
     * bağlayan kişi müzik değil, zil sesi duymak istiyor.
     */
    fun isFreeForMusic(context: Context): Boolean =
        mode(context) == AudioManager.MODE_NORMAL

    private fun mode(context: Context): Int {
        val manager =
            context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        // Ses yöneticisi alınamazsa engellemiyoruz: bilmemek, çalmayı
        // yasaklamak için yeterli sebep değil.
        return manager?.mode ?: AudioManager.MODE_NORMAL
    }
}
