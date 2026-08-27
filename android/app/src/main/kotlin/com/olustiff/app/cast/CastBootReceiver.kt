package com.olustiff.app.cast

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Televizyon açılınca yayın alıcısını ayağa kaldırır.
 *
 * Olmadan, kullanıcının televizyonda uygulamayı EN AZ BİR KEZ açması
 * gerekiyordu — telefondan gönderebilmek için önce televizyona gidip
 * kumandayla uygulamayı açmak, özelliğin bütün anlamını yok ediyordu.
 *
 * Neden BOOT_COMPLETED'dan ön plan servisi başlatmak serbest: Android 12+
 * arka plandan ön plan servisi başlatmayı genel olarak yasaklıyor ama
 * açılış yayınını alan uygulamalar bu yasağın dışında tutuluyor. Yine de
 * `startForegroundService` çağrısı [CastReceiverService.start] içinde
 * korumalı: reddedilirse uygulama normal çalışmaya devam eder, yalnızca
 * kullanıcının televizyonda uygulamayı bir kez açması gerekir.
 *
 * `QUICKBOOT_POWERON`: bazı TV kutuları ve üreticiler (özellikle HTC/Xiaomi
 * türevi ROM'lar) standart açılış yayınını göndermeyip bunu gönderiyor.
 */
class CastBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null) return
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != QUICKBOOT_POWERON
        ) {
            return
        }
        // Telefonda hiç başlatılmıyor: [CastReceiverService.start] televizyon
        // olmayan cihazlarda sessizce çıkıyor.
        CastReceiverService.start(context)
    }

    private companion object {
        const val QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
}
