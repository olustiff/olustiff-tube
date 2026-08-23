package com.olustiff.app.player

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Bluetooth ses aygıtı bağlanınca çalmaya devam eder.
 *
 * Uygulamanın ekranını AÇMAZ: Android 10'dan beri arka plandan aktivite
 * başlatmak engelli. Bunun yerine son çalınan parçayı arka planda başlatır —
 * kulaklığı takınca müziğin gelmesi zaten istenen davranış.
 */
class BluetoothAutoPlayReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BluetoothDevice.ACTION_ACL_CONNECTED) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        // Yalnızca ses aygıtları: klavye, saat vb. müzik başlatmamalı.
        val audioManager = context.getSystemService(AudioManager::class.java)
        if (audioManager?.isBluetoothA2dpOn != true) return

        val videoId = prefs.getString(KEY_LAST_VIDEO, null) ?: return

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        scope.launch {
            try {
                val appContext = context.applicationContext
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
            } catch (e: Exception) {
                Log.w("AkisBluetooth", "Otomatik çalma başarısız", e)
            }
        }
    }

    companion object {
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
