package com.olustiff.app.player

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Bluetooth ses aygıtı bağlanınca çalmaya devam eder.
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

        // onReceive dönünce süreç öldürülebilir; asenkron iş bitene kadar
        // sistemin bizi canlı tutması için goAsync() gerekiyor.
        val pending = goAsync()
        val appContext = context.applicationContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

        scope.launch {
            try {
                appContext.startService(
                    Intent(appContext, PlaybackService::class.java)
                )
                PlaybackQueue.set(
                    listOf(
                        PlaybackQueue.Item(
                            videoId = videoId,
                            title = prefs.getString(KEY_LAST_TITLE, "") ?: "",
                            uploaderName = prefs.getString(KEY_LAST_ARTIST, null),
                            thumbnailUrl = null
                        )
                    ),
                    startIndex = -1
                )
                PlayerHolder.playNext(appContext)
                Log.d(TAG, "Otomatik çalma başlatıldı: $videoId")
            } catch (e: Exception) {
                Log.w(TAG, "Otomatik çalma başarısız", e)
            } finally {
                pending.finish()
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
