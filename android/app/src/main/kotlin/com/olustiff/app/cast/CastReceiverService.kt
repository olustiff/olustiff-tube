package com.olustiff.app.cast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Yayın (cast) alıcısını AKTİVİTEDEN BAĞIMSIZ yaşatan ön plan servisi.
 *
 * Neden var: alıcı eskiden `MainActivity` ile birlikte doğup ölüyordu.
 * Televizyonda uygulama kapalıyken hiçbir port dinlenmiyordu; telefon
 * televizyonu keşifte HİÇ göremiyor, kullanıcı da "aynı ağdayız ama
 * bulamıyor" diyordu. Oysa kullanıcının beklentisi haklı: telefondan
 * gönderince televizyonda uygulama kendiliğinden açılmalı.
 *
 * Neden ÖN PLAN servisi: Android 8'den beri arka plan servisleri birkaç
 * dakika içinde öldürülüyor. Ağı sürekli dinlemesi gereken bir servis ancak
 * ön planda kalıcı olabiliyor.
 *
 * Pil maliyeti neden kabul edilebilir: servis YALNIZCA TELEVİZYONDA açılıyor
 * (bkz. [isTelevision]) ve televizyon prize takılı. Yaptığı iş iki soket
 * üzerinde bloke beklemek — paket gelmediği sürece CPU kullanmıyor. Telefonda
 * bu servis hiç başlatılmıyor; orada uygulama gönderen taraf.
 *
 * Servisi ayakta tutan iki şey:
 * 1. Açılışta [CastBootReceiver] başlatıyor (televizyon fişe takılınca hazır).
 * 2. Uygulama her açıldığında `MainActivity` yeniden başlatıyor (servis
 *    herhangi bir sebeple öldüyse toparlansın).
 */
class CastReceiverService : Service() {

    override fun onCreate() {
        super.onCreate()
        com.olustiff.app.Lang.init(this)
        // Bildirim ÖNCE: Android, `startForegroundService` ile başlatılan bir
        // servis 5 saniye içinde `startForeground` çağırmazsa süreci
        // ANR ile öldürüyor.
        startForeground(NOTIFICATION_ID, notification())
        CastHub.receiver(this).start()
    }

    /**
     * START_STICKY: sistem belleği toparlamak için servisi öldürürse geri
     * getirsin. Alıcının sürekli açık olması bu özelliğin tamamı.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        CastHub.receiver(this).start()
        return START_STICKY
    }

    /** Bağlanılmıyor: servis yalnızca ağı dinliyor. */
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        CastHub.stop()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_LOW: ses çıkarmasın, televizyonun üstünde uyarı
            // olarak belirmesin — bu bildirim yalnızca sistemin şart koştuğu
            // "servis çalışıyor" göstergesi.
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Yayın alıcısı",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Telefondan gelen videoları karşılar"
                setShowBadge(false)
            }
            manager?.createNotificationChannel(channel)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("oLusTifF yayına hazır")
            .setContentText("Telefondan gönderilen videoları bekliyor")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "olustiff-cast-receiver"
        private const val NOTIFICATION_ID = 4711
        private const val TAG = "CastReceiverService"

        /**
         * Servisi başlatır — YALNIZCA televizyonda.
         *
         * Hata YUTULUYOR: Android 12+ arka plandan ön plan servisi başlatmayı
         * kısıtlıyor ve reddedildiğinde istisna fırlatıyor. Yayın yalnızca bir
         * ek özellik; başlatılamazsa uygulama normal çalışmaya devam etmeli.
         */
        fun start(context: Context) {
            if (!isTelevision(context)) return
            val intent = Intent(context, CastReceiverService::class.java)
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }.onFailure { Log.w(TAG, "Yayın alıcısı servisi başlatılamadı", it) }
        }

        /**
         * Cihaz televizyon mu.
         *
         * `MainActivity` ile AYNI ölçüt: bazı TV kutuları `UiModeManager`'ı
         * doğru bildirmiyor, leanback özelliği daha güvenilir bir işaret.
         */
        fun isTelevision(context: Context): Boolean {
            val uiMode = context.getSystemService(Context.UI_MODE_SERVICE)
                as? UiModeManager
            if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
                return true
            }
            return context.packageManager
                .hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        }
    }
}

/**
 * Alıcının tek sahibi.
 *
 * Hem servis hem aktivite aynı alıcıya ulaşmak zorunda: servis onu AYAKTA
 * tutuyor, aktivite ise Flutter kanalını takıp söküyor. İki ayrı örnek
 * olsaydı ikisi de aynı portu bağlamaya çalışır ve ikincisi sessizce
 * başarısız olurdu.
 */
object CastHub {

    @Volatile
    private var receiver: CastReceiver? = null

    @Synchronized
    fun receiver(context: Context): CastReceiver {
        val existing = receiver
        if (existing != null) return existing
        val app = context.applicationContext
        return CastReceiver(
            context = app,
            bringToFront = { launchApp(app) }
        ).also { receiver = it }
    }

    @Synchronized
    fun stop() {
        receiver?.stop()
        receiver = null
    }

    /**
     * Uygulamayı açar / öne getirir.
     *
     * Aktivite YOKKEN de çağrılabilmeli (uygulama televizyonda hiç açık
     * değilken yayın geldiğinde), bu yüzden uygulama bağlamı ve
     * `FLAG_ACTIVITY_NEW_TASK` kullanılıyor.
     *
     * Not: Android 10+ arka plandaki uygulamaların aktivite açmasını
     * kısıtlıyor. Pil optimizasyonundan muaf tutulan uygulamalar bu
     * kısıtlamadan etkilenmiyor — ayarlardaki "Televizyonda yayına hazır ol"
     * akışı bu muafiyeti istiyor.
     */
    private fun launchApp(context: Context) {
        wakeScreen(context)
        val intent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?: return
        intent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        )
        runCatching { context.startActivity(intent) }
            .onFailure { Log.w("CastHub", "Uygulama açılamadı", it) }
    }

    /**
     * Ekranı uyandırır ve ekran koruyucuyu düşürür.
     *
     * Televizyon boştayken ekran koruyucuya geçiyor; uyandırmadan açılan
     * aktivite arkada kalıyor ve kullanıcı yalnızca sesi duyuyordu.
     */
    private fun wakeScreen(context: Context) {
        val power = context.getSystemService(PowerManager::class.java) ?: return
        runCatching {
            @Suppress("DEPRECATION")
            power.newWakeLock(
                PowerManager.FULL_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "olustiff:cast"
            ).acquire(WAKE_TIMEOUT_MS)
        }
    }

    /** Ekranı açık TUTMAK oynatma ekranının işi; buradaki amaç uyandırmak. */
    private const val WAKE_TIMEOUT_MS = 10_000L
}
