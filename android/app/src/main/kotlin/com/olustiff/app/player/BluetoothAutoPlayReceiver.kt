package com.olustiff.app.player

import android.bluetooth.BluetoothA2dp
import com.olustiff.app.Lang
import com.olustiff.app.diag.Tanilama
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import com.olustiff.app.extractor.ExtractionService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.stream.StreamInfoItem

/**
 * Bluetooth ses aygıtı bağlanınca çalmaya devam eder.
 *
 * Görüşme sürerken BAŞLATMAZ: telefonla konuşurken kulaklık bağlandığında
 * müzik çalmaya başlıyordu (bkz. [startSavedTrack]).
 *
 * Uygulamanın ekranını AÇMAZ: Android 10'dan beri arka plandan aktivite
 * başlatmak engelli. Bunun yerine son çalınan parçayı arka planda başlatır.
 *
 * Neden ACL_CONNECTED değil de A2DP olayı: cihaz "bağlandı" (ACL) anında ses
 * profili (A2DP) henüz kurulmamış oluyor — kulaklık önce bağlanır, müzik
 * kanalı saniyeler sonra açılır. ACL anında çalmaya kalkmak sesin telefon
 * hoparlöründen çıkmasına ya da hiç başlamamasına yol açıyordu.
 */
class BluetoothAutoPlayReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED) return
        Tanilama.init(context)

        val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)
        if (state != BluetoothProfile.STATE_CONNECTED) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            Log.d(TAG, "Otomatik çalma kapalı")
            return
        }

        val videoId = prefs.getString(KEY_LAST_VIDEO, null)
        if (videoId.isNullOrBlank()) {
            Log.d(TAG, "Çalınacak parça kayıtlı değil")
            return
        }

        // Yayın, oynatmanın BAŞLAMASINI beklemeden kapatılıyor.
        //
        // Eskiden `goAsync()` bütün işi kapsıyordu ve iş ağ gerektiriyor:
        // arabada sinyal zayıfken çıkarma on saniyeyi aşıyor, sistem de
        // yayın alıcısına o kadar süre tanımıyor. Sonuç gerçek cihazda
        // yakalandı — `BluetoothAutoPlayReceiver` için ANR kaydı,
        // üstelik A2DP yayını bağlantı sırasında arka arkaya onlarca kez
        // geliyor ve her biri ana thread'i meşgul ediyor.
        //
        // Süreci canlı tutan şey artık yayın değil, başlatılan ön plan
        // servisi; alıcının uzun işi omzunda taşımasına gerek yok.
        val app = context.applicationContext
        val pending = goAsync()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope.launch {
            try {
                // Servis ayağa kalkar kalkmaz yayını serbest bırakıyoruz.
                app.startService(Intent(app, PlaybackService::class.java))
            } catch (e: Exception) {
                Tanilama.olay(TAG, "Oynatma servisi başlatılamadı", e)
            } finally {
                pending.finish()
            }

            try {
                startSavedTrack(app)
            } catch (e: Exception) {
                Tanilama.olay(TAG, "Otomatik çalma başarısız", e)
            }
        }
    }

    companion object {
        private const val TAG = "OlustiffBluetooth"

        const val PREFS = "olustiff_bluetooth"
        const val KEY_ENABLED = "auto_play_enabled"
        const val KEY_LAST_VIDEO = "last_video_id"
        const val KEY_LAST_TITLE = "last_title"
        const val KEY_LAST_ARTIST = "last_artist"

        /**
         * Kayıtlı parçayı arka planda başlatır.
         *
         * Hem bluetooth yayınından hem de ayarlardaki "şimdi dene"
         * düğmesinden çağrılır: yayın sistem korumalı olduğu için
         * kulaklık bağlamadan test etmenin başka yolu yok.
         *
         * Başarılıysa null, değilse sorunu anlatan bir metin döner.
         */
        suspend fun startSavedTrack(context: Context): String? {
            // Konuşurken kulaklık bağlayan kişi müzik istemiyor.
            //
            // Gerçek kullanımda yaşandı: telefonla konuşurken kulaklık
            // bağlanınca müzik çalmaya başlıyordu. Bluetooth yayını aramadan
            // haberdar değil; ses kipine bakmak bunu izinsiz ve VoIP
            // aramalarını da kapsayacak şekilde çözüyor.
            //
            // Telefon ÇALARKEN de başlatmıyoruz (bkz. [CallState.isFreeForMusic]):
            // o anda kulaklık bağlayan kişi zil sesi duymak istiyor.
            if (!CallState.isFreeForMusic(context)) {
                Log.d(TAG, "Görüşme sürüyor, otomatik çalma başlatılmadı")
                return Lang.tr("Şu an bir görüşme sürüyor; müzik başlatılmadı.", "A call is in progress; music wasn't started.")
            }

            // Elde zaten bir şey varsa KUYRUĞA DOKUNMA, kaldığı yerden sürdür.
            //
            // Eskiden koşulsuz olarak kayıtlı parça baştan açılıyor ve o anki
            // kuyruk siliniyordu: uygulama açıkken, hatta müzik çalarken
            // kulaklık bağlandığında dinlenen şey kesilip en son açılan parça
            // baştan başlıyordu. Arabada kontak her açıldığında yaşanıyor.
            // Bluetooth yeniden bağlandı: çıkış kilidi kalkar (yoksa
            // sıfırdan açılan parça da sessiz beklerdi).
            PlayerHolder.userIntent()
            if (PlayerHolder.hasMedia) {
                PlayerHolder.resume()
                Log.d(TAG, "Oynatma zaten yüklü, kaldığı yerden sürdürüldü")
                return null
            }

            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val videoId = prefs.getString(KEY_LAST_VIDEO, null)
            if (videoId.isNullOrBlank()) {
                Log.d(TAG, "Çalınacak parça kayıtlı değil")
                return Lang.tr("Önce bir şey çal — kayıtlı parça yok.", "Play something first — there's no saved track.")
            }
            return try {
                context.startService(Intent(context, PlaybackService::class.java))
                // Kuyruğu ilgili videolarla doldur: tek parçalık kuyrukta
                // şarkı bitince çalma duruyordu.
                val queue = withContext(Dispatchers.IO) {
                    buildQueue(videoId, prefs)
                }
                PlaybackQueue.set(queue, startIndex = -1)
                // Süreç yeni başladıysa mod varsayılan "video"da; kullanıcının
                // seçtiği modu yükle.
                PlayerHolder.restoreSavedMode(context)
                PlayerHolder.playNext(context)
                Log.d(TAG, "Otomatik çalma başlatıldı: $videoId")
                null
            } catch (e: Exception) {
                Tanilama.olay(TAG, "Otomatik çalma başarısız", e)
                e.message ?: Lang.tr("Bilinmeyen hata", "Unknown error")
            }
        }

        /** Kuyruğa alınacak ilgili video sayısı; fazlası gereksiz. */
        private const val RELATED_LIMIT = 20

        /**
         * Kayıtlı parçayı ve devamında çalacak ilgili videoları hazırlar.
         *
         * İlgili videolar alınamazsa en azından kayıtlı parça çalsın diye
         * hata yutulur — sessiz kalmaktansa tek şarkı çalmak yeğdir.
         */
        private fun buildQueue(
            videoId: String,
            prefs: SharedPreferences
        ): List<PlaybackQueue.Item> {
            val first = PlaybackQueue.Item(
                videoId = videoId,
                title = prefs.getString(KEY_LAST_TITLE, "") ?: "",
                uploaderName = prefs.getString(KEY_LAST_ARTIST, null),
                thumbnailUrl = null
            )
            return try {
                val related = ExtractionService.streamInfo(videoId)
                    .relatedItems
                    .filterIsInstance<StreamInfoItem>()
                    .mapNotNull { item ->
                        ExtractionService.extractVideoId(item.url)?.let { id ->
                            PlaybackQueue.Item(
                                videoId = id,
                                title = item.name ?: "",
                                uploaderName = item.uploaderName,
                                thumbnailUrl = null
                            )
                        }
                    }
                    .filter { it.videoId != videoId }
                    .take(RELATED_LIMIT)
                listOf(first) + related
            } catch (e: Exception) {
                Tanilama.olay(TAG, "İlgili videolar alınamadı, tek parça çalınacak", e)
                listOf(first)
            }
        }

        /** Son çalınanı saklar; bluetooth bağlanınca bu kaldığı yerden çalar. */
        fun rememberLastPlayed(
            context: Context,
            videoId: String,
            title: String,
            artist: String?
        ) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_LAST_VIDEO, videoId)
                .putString(KEY_LAST_TITLE, title)
                .putString(KEY_LAST_ARTIST, artist)
                .apply()
        }

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_ENABLED, enabled)
                .apply()
        }

        fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }
}
