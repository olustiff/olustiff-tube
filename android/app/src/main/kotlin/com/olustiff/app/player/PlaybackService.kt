package com.olustiff.app.player

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.olustiff.app.MainActivity
import com.olustiff.app.R

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
        com.olustiff.app.Lang.init(this)

        val sessionActivityIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Sarmalayıcı, bildirim ve kilit ekranındaki ileri/geri düğmelerini
        // kendi kuyruğumuza bağlar (bkz. QueueAwarePlayer).
        val session = MediaSession.Builder(
            this,
            QueueAwarePlayer(this, PlayerHolder.getPlayer(this))
        )
            .setSessionActivity(sessionActivityIntent)
            .setCallback(CloseCallback())
            // Bildirimde kapatma düğmesi: çalarken bildirim kaydırılarak
            // kapatılamıyor, kullanıcının oynatmayı bitirmek için uygulamayı
            // açması gerekiyordu.
            .setCustomLayout(ImmutableList.of(closeButton()))
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

    private fun closeButton(): CommandButton = CommandButton.Builder()
        .setDisplayName("Kapat")
        .setIconResId(R.drawable.ic_notification_close)
        .setSessionCommand(SessionCommand(ACTION_CLOSE, Bundle.EMPTY))
        // Düğme sırasının SAĞ ucuna yerleşsin. Bildirimin sağ ÜST köşesi
        // (medya çıkışı seçicisinin olduğu yer) sistem arayüzüne ait;
        // uygulama oraya düğme koyamıyor. Yer bulunamazsa taşma menüsüne.
        .setSlots(
            CommandButton.SLOT_FORWARD_SECONDARY,
            CommandButton.SLOT_OVERFLOW
        )
        .build()

    /** "Kapat" düğmesini kullanılabilir kılar ve basıldığında oynatmayı bitirir. */
    private inner class CloseCallback : MediaSession.Callback {

        override fun onConnect(
            session: MediaSession,
            controller: MediaSession.ControllerInfo
        ): MediaSession.ConnectionResult {
            val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS
                .buildUpon()
                .add(SessionCommand(ACTION_CLOSE, Bundle.EMPTY))
                .build()

            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(commands)
                .build()
        }

        override fun onCustomCommand(
            session: MediaSession,
            controller: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle
        ): ListenableFuture<SessionResult> {
            if (customCommand.customAction != ACTION_CLOSE) {
                return super.onCustomCommand(session, controller, customCommand, args)
            }

            // Kuyruğu da boşalt: yalnızca durdurmak bildirimi ayakta
            // bırakıyor, kullanıcı ise oynatmayı bitirmek istiyor.
            // Alttaki oynatıcı DOĞRUDAN durduruluyor: oturumun oynatıcısı
            // (QueueAwarePlayer) dışarıdan gelen "stop"u duraklatmaya
            // çeviriyor (araba teybi), "Kapat" ise gerçekten kapatmalı.
            val player = PlayerHolder.getPlayer(this@PlaybackService)
            player.stop()
            player.clearMediaItems()
            PlaybackQueue.clear()
            stopSelf()

            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }
    }

    private companion object {
        const val ACTION_CLOSE = "com.olustiff.app.CLOSE"
    }

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
