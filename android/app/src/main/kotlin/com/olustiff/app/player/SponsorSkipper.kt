package com.olustiff.app.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.media3.exoplayer.ExoPlayer
import com.olustiff.app.Lang
import com.olustiff.app.diag.Tanilama
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * SponsorBlock: videonun İÇİNE gömülü sponsor, kendi tanıtımı ve "abone ol"
 * bölümlerini atlar.
 *
 * YouTube reklamı zaten gösterilmiyor; bu, içerik üreticisinin videoya
 * kendisinin koyduğu tanıtım. Bölümlerin saniyelerini kullanıcıların
 * işaretlediği ortak veritabanından (sponsor.ajay.app) alıyoruz.
 *
 * ## Gizlilik
 *
 * Sunucuya video kimliği GÖNDERİLMİYOR: kimliğin SHA-256 özetinin ilk 4
 * karakteri gidiyor, sunucu o önekle başlayan bütün videoların bölümlerini
 * dönüyor, doğrusu burada seçiliyor (SponsorBlock'un önerdiği yöntem).
 *
 * ## Neden native tarafta
 *
 * Ekran kapalıyken ve kuyruk kendi başına ilerlerken de atlamalı; Dart
 * arayüzü o sırada çalışmıyor olabilir.
 */
object SponsorSkipper {
    private const val TAG = "SponsorSkipper"
    private const val CHECK_MS = 500L
    private const val PREF_KEY = "flutter.sponsor_block"

    /**
     * Atlanacak türler. `music_offtopic`: müzik videolarındaki müzik dışı
     * kısımlar (girişteki konuşma, klip öncesi sahne) — bu uygulamada çok
     * müzik dinleniyor, en çok işe yarayan tür bu.
     */
    private val CATEGORIES = listOf("sponsor", "selfpromo", "interaction", "music_offtopic")

    @Volatile
    var enabled: Boolean = true
        private set

    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val http = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .build()

    /** videoId → bölümler. Boş liste: sorgulandı, bölüm yok. */
    private val cache = ConcurrentHashMap<String, List<Segment>>()
    private val pending = ConcurrentHashMap.newKeySet<String>()

    private var appContext: Context? = null
    private var playerProvider: (() -> ExoPlayer?)? = null
    private var started = false

    /** Bu çalışta atlanmış bölümler: kullanıcı geri sarıp o kısma dönerse tekrar atlamıyoruz. */
    private var skippedFor: String? = null
    private val skipped = mutableSetOf<Segment>()

    data class Segment(val startMs: Long, val endMs: Long, val category: String)

    fun start(context: Context, player: () -> ExoPlayer?) {
        appContext = context.applicationContext
        playerProvider = player
        enabled = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean(PREF_KEY, true)
        if (started) return
        started = true
        handler.postDelayed(tick, CHECK_MS)
    }

    fun setEnabled(value: Boolean) {
        enabled = value
    }

    private val tick = object : Runnable {
        override fun run() {
            handler.postDelayed(this, CHECK_MS)
            if (!enabled) return
            val player = playerProvider?.invoke() ?: return
            val videoId = PlaybackQueue.current()?.videoId ?: return
            if (player.isCurrentMediaItemLive) return
            val segments = cache[videoId]
            if (segments == null) {
                fetch(videoId)
                return
            }
            if (skippedFor != videoId) {
                skippedFor = videoId
                skipped.clear()
            }
            if (!player.isPlaying) return
            val target = segmentToSkip(segments, player.currentPosition, skipped) ?: return
            skipped += target
            val duration = player.duration
            // Bölüm videonun sonuna kadar uzanıyorsa sona atlamak parçayı
            // bitirir: kuyruk sıradakine geçer, beklenen de bu.
            val to = if (duration > 0) minOf(target.endMs, duration) else target.endMs
            player.seekTo(to)
            Tanilama.olay(TAG, "${target.category} atlandı ($videoId, ${target.startMs / 1000}-${target.endMs / 1000} sn)")
            appContext?.let {
                Toast.makeText(it, label(target.category), Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun label(category: String) = when (category) {
        "sponsor" -> Lang.tr("Sponsor bölümü atlandı", "Sponsor segment skipped")
        "selfpromo" -> Lang.tr("Tanıtım bölümü atlandı", "Self-promotion skipped")
        "interaction" -> Lang.tr("\"Abone ol\" hatırlatması atlandı", "Subscribe reminder skipped")
        "music_offtopic" -> Lang.tr("Müzik dışı bölüm atlandı", "Non-music section skipped")
        else -> Lang.tr("Bölüm atlandı", "Segment skipped")
    }

    /**
     * [positionMs] bir bölümün içindeyse o bölümü döner.
     *
     * Bölümün son yarım saniyesinde atlamıyoruz: oraya gelindiyse bölüm
     * zaten bitiyor, atlamak yalnızca küçük bir sıçrama yaratır.
     */
    fun segmentToSkip(segments: List<Segment>, positionMs: Long, alreadySkipped: Set<Segment>): Segment? =
        segments.firstOrNull { s ->
            s !in alreadySkipped && positionMs >= s.startMs && positionMs < s.endMs - 500
        }

    private fun fetch(videoId: String) {
        if (!pending.add(videoId)) return
        scope.launch {
            try {
                cache[videoId] = query(videoId)
            } catch (e: Exception) {
                // Ağ yoksa ya da sunucu çöktüyse video atlamasız oynar. Bu
                // video için yeniden sorulmuyor: her yarım saniyede bir
                // başarısız istek atmak boşuna pil harcardı.
                Tanilama.olay(TAG, "Bölümler alınamadı ($videoId)", e)
                cache[videoId] = emptyList()
            } finally {
                pending.remove(videoId)
            }
        }
    }

    private fun query(videoId: String): List<Segment> {
        val prefix = sha256(videoId).take(4)
        val categories = URLEncoder.encode(JSONArray(CATEGORIES).toString(), "UTF-8")
        val request = Request.Builder()
            .url("https://sponsor.ajay.app/api/skipSegments/$prefix?categories=$categories&actionType=skip")
            .build()
        http.newCall(request).execute().use { response ->
            if (response.code == 404) return emptyList()
            if (!response.isSuccessful) error("HTTP ${response.code}")
            return parse(response.body?.string() ?: return emptyList(), videoId)
        }
    }

    fun parse(json: String, videoId: String): List<Segment> {
        val videos = JSONArray(json)
        for (i in 0 until videos.length()) {
            val video = videos.getJSONObject(i)
            if (video.optString("videoID") != videoId) continue
            val segments = video.optJSONArray("segments") ?: return emptyList()
            return (0 until segments.length()).mapNotNull { j ->
                val s = segments.getJSONObject(j)
                if (s.optString("actionType", "skip") != "skip") return@mapNotNull null
                val range = s.getJSONArray("segment")
                val start = (range.getDouble(0) * 1000).toLong()
                val end = (range.getDouble(1) * 1000).toLong()
                // 1 saniyeden kısa bölümler işaretleme hatası; atlamak
                // yalnızca rahatsız eder.
                if (end - start < 1000) null else Segment(start, end, s.optString("category"))
            }.sortedBy { it.startMs }
        }
        return emptyList()
    }

    private fun sha256(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
            .joinToString("") { "%02x".format(it) }
}
