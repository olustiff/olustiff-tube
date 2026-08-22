package com.utkuhalis.akis.player

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.utkuhalis.akis.MainActivity

/**
 * Uygulama arka plana alınsa ya da video ekranı kapatılsa bile oynatmayı
 * sürdüren medya oturumu — bildirimden ve kilit ekranından kontrol edilebilir.
 *
 * Player'ın kendisi [PlayerHolder]'da yaşıyor; bu servis onu yalnızca bir
 * MediaSession'a bağlar. Video yüzeyi ayrı olarak
 * [PlayerPlatformView] tarafından aynı player'a takılıp çıkarılır. Bu ayrım
 * sayesinde "ekranı kapat, müzik devam etsin" davranışı doğaldır ve akış asla
 * kendiliğinden video görünümüne geri dönmez.
 */
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()

        val sessionActivityIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val session = MediaSession.Builder(this, PlayerHolder.getPlayer(this))
            .setSessionActivity(sessionActivityIntent)
            .build()
        mediaSession = session

        // Oturumu servise kendimiz kaydediyoruz: aksi hâlde kayıt yalnızca bir
        // MediaController bağlandığında yapılır ve medya bildirimi hiç
        // oluşmaz. Bildirim olmadan Media3 startForeground çağıramaz, servis
        // de arka planda öldürülürdü.
        addSession(session)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    /**
     * Kullanıcı uygulamayı görev listesinden kaydırdığında: oynatma duraklamışsa
     * servisi kapat, ama çalmaya devam ediyorsa (arka planda müzik senaryosu)
     * ayakta tut.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = PlayerHolder.getPlayer(this)
        if (!player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        mediaSession?.release()
        mediaSession = null
        PlayerHolder.release()
        super.onDestroy()
    }
}
