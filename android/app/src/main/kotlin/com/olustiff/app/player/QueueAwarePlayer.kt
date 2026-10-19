package com.olustiff.app.player

import android.content.Context
import com.olustiff.app.diag.Tanilama
import android.util.Log
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Medya oturumuna verilen player sarmalayıcısı.
 *
 * Neden gerekli: kuyruğumuz [PlaybackQueue]'da yaşıyor, ExoPlayer'ın kendi
 * oynatma listesi ise tek öğeli. Media3'ün bildirim sağlayıcısı ileri/geri
 * düğmelerini `COMMAND_SEEK_TO_NEXT/PREVIOUS` komutlarının varlığına bakarak
 * çiziyor; sarmalamadan bu komutlar "yok" göründüğü için bildirimde ve kilit
 * ekranında sonraki/önceki düğmeleri hiç çıkmıyordu.
 *
 * Burada komutları kuyruğun durumuna göre bildiriyor ve atlama isteklerini
 * kendi kuyruğumuza yönlendiriyoruz.
 */
class QueueAwarePlayer(
    private val context: Context,
    player: Player
) : ForwardingPlayer(player) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun getAvailableCommands(): Player.Commands {
        return super.getAvailableCommands().buildUpon()
            .addIf(Player.COMMAND_SEEK_TO_NEXT, PlaybackQueue.hasNext())
            .addIf(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, PlaybackQueue.hasNext())
            .addIf(Player.COMMAND_SEEK_TO_PREVIOUS, PlaybackQueue.hasPrevious())
            .addIf(
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                PlaybackQueue.hasPrevious()
            )
            .build()
    }

    override fun isCommandAvailable(command: Int): Boolean =
        availableCommands.contains(command)

    override fun hasNextMediaItem(): Boolean = PlaybackQueue.hasNext()

    override fun hasPreviousMediaItem(): Boolean = PlaybackQueue.hasPrevious()

    override fun seekToNext() = goNext()

    override fun seekToNextMediaItem() = goNext()

    override fun seekToPrevious() = goPrevious()

    override fun seekToPreviousMediaItem() = goPrevious()

    // Bildirim, kilit ekranı, araba teybi ve direksiyon tuşları buradan
    // geliyor: hepsi kullanıcının iradesi, çıkış kilidini kaldırır.
    override fun play() {
        PlayerHolder.userIntent()
        super.play()
    }

    override fun setPlayWhenReady(playWhenReady: Boolean) {
        if (playWhenReady) PlayerHolder.userIntent()
        super.setPlayWhenReady(playWhenReady)
    }

    private fun goNext() {
        PlayerHolder.userIntent()
        scope.launch { guarded { PlayerHolder.playNext(context) } }
    }

    /**
     * Oynatma adımını çalıştırır, istisnayı yutmadan günlüğe yazar.
     *
     * Buradaki koruma özellikle önemli: arabanın direksiyon ve teyp
     * tuşlarından gelen "sonraki/önceki" komutları bu yoldan geçiyor.
     * Korumasızken ağ sektiğinde yakalanmayan istisna süreci öldürüyordu —
     * kullanıcı bunu "tuşa bastım, müzik komple durdu" diye görüyor.
     */
    private suspend fun guarded(step: suspend () -> Unit) {
        try {
            step()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Tanilama.olay("OlustiffQueuePlayer", "Kuyruk komutu başarısız", e)
        }
    }

    /**
     * Parçanın başına sarma yerine gerçekten önceki parçaya geçer; kuyruğun
     * başındaysak başa sarmak daha doğal olduğu için o davranışa düşeriz.
     */
    private fun goPrevious() {
        PlayerHolder.userIntent()
        if (!PlaybackQueue.hasPrevious()) {
            seekTo(0)
            return
        }
        scope.launch { guarded { PlayerHolder.playPrevious(context) } }
    }
}
