package com.olustiff.app.player

import androidx.media3.common.PlaybackException
import com.olustiff.app.player.RecoveryPolicy.OpenFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.UnknownHostException

/**
 * Kurtarma kararlarının testleri. Her biri GERÇEKTE YAŞANMIŞ bir hatayı
 * temsil ediyor; açıklamada ne olduğu yazıyor.
 */
class RecoveryPolicyTest {

    private val policy = RecoveryPolicy(stallLimitMs = 12_000L, maxNetworkRetries = 5, maxSkips = 3)

    // ---- Ses çıkışı kilidi -------------------------------------------------

    /** Arabada Bluetooth koptu, odak geri gelince müzik HOPARLÖRDEN başladı. */
    @Test
    fun cikisKopunca_otomatikBaslatmaYasak() {
        assertTrue(policy.onOutputLost(wasPlaying = true))
        assertFalse(policy.mayAutoStart())
        assertFalse(policy.mayAutoStart(wanted = true))
    }

    @Test
    fun kullaniciKomutu_kilidiKaldirir() {
        policy.onOutputLost(wasPlaying = true)
        assertTrue(policy.onUserIntent())
        assertTrue(policy.mayAutoStart())
        // Kilit yokken komut yeni bir olay değil (günlük dolmasın).
        assertFalse(policy.onUserIntent())
    }

    @Test
    fun cikisGeriGelince_kilitKalkar() {
        policy.onOutputLost(wasPlaying = false)
        policy.onOutputRestored()
        assertTrue(policy.mayAutoStart())
    }

    /** Sistem yayını ve cihaz listesi aynı kopmayı ardışık bildiriyor. */
    @Test
    fun ayniKopmaIkiKezBildirilince_tekOlay() {
        assertTrue(policy.onOutputLost(wasPlaying = true))
        assertFalse(policy.onOutputLost(wasPlaying = false))
    }

    /** Kilitliyken kullanıcı başlatıp çalarken yeniden kopma: yeni olay. */
    @Test
    fun kilitliykenCalarkenKopma_yeniOlay() {
        policy.onOutputLost(wasPlaying = false)
        assertTrue(policy.onOutputLost(wasPlaying = true))
    }

    @Test
    fun duraklatilmisParca_otomatikBaslamaz() {
        assertFalse(policy.mayAutoStart(wanted = false))
        assertTrue(policy.mayAutoStart(wanted = true))
    }

    // ---- Adres tazeleme hakkı ----------------------------------------------

    @Test
    fun tazelemeHakki_parcaBasinaBirKez() {
        assertTrue(policy.claimRefresh("a"))
        assertFalse(policy.claimRefresh("a"))
    }

    /** Hata ve takılma aynı parçayı ayrı ayrı tazeliyordu. */
    @Test
    fun hataVeTakilma_ayniHakkiPaylasir() {
        assertTrue(policy.claimRefresh("a")) // 403
        assertFalse(policy.claimRefresh("a")) // ardından takılma bekçisi
    }

    @Test
    fun baskaParca_kendiHakkiniAlir() {
        assertTrue(policy.claimRefresh("a"))
        assertTrue(policy.claimRefresh("b"))
    }

    @Test
    fun parcaAkinca_hakYenilenir() {
        policy.claimRefresh("a")
        policy.onReady()
        assertTrue(policy.claimRefresh("a"))
    }

    @Test
    fun yalnizcaGirisCikisHatalariTazelenir() {
        assertTrue(policy.isRefreshable(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS))
        assertTrue(policy.isRefreshable(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED))
        assertTrue(policy.isRefreshable(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT))
        assertFalse(policy.isRefreshable(PlaybackException.ERROR_CODE_DECODING_FAILED))
        assertFalse(policy.isRefreshable(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED))
    }

    /** Sabitler Media3'ten kopya; Media3 değiştirirse burada yakalansın. */
    @Test
    fun ioAraligi_media3IleAyni() {
        assertEquals(PlaybackException.ERROR_CODE_IO_UNSPECIFIED, RecoveryPolicy.IO_ERROR_FIRST)
        assertEquals(PlaybackException.ERROR_CODE_IO_NO_PERMISSION, RecoveryPolicy.IO_ERROR_LAST)
    }

    // ---- Adresin süresi ------------------------------------------------------

    /** 25 Ekim: sabah duraklatılan video akşam sürdürüldü, adres 8 saatlikti. */
    @Test
    fun suresiDolmusAdres_tazelenir() {
        assertTrue(policy.isExpiring(expireEpochSec = 1_000, nowEpochSec = 1_000 + 2 * 3600))
    }

    @Test
    fun suresiDolmakUzereAdres_tazelenir() {
        assertTrue(policy.isExpiring(expireEpochSec = 10_000, nowEpochSec = 10_000 - 5 * 60))
    }

    @Test
    fun tazeAdres_dokunulmaz() {
        assertFalse(policy.isExpiring(expireEpochSec = 10_000 + 6 * 3600, nowEpochSec = 10_000))
    }

    /** Canlı yayın / indirilmiş dosya: süre bilinmiyor, tazeleme yok. */
    @Test
    fun suresiBilinmeyenAdres_dokunulmaz() {
        assertFalse(policy.isExpiring(expireEpochSec = null, nowEpochSec = 10_000))
    }

    // ---- Takılma -------------------------------------------------------------

    /** Cihazda ~50 sn hatasız "yükleniyor": tampon hiç büyümedi. */
    @Test
    fun tamponBuyumuyorsa_12snSonraTakilma() {
        assertFalse(policy.observeStall(0, waiting = true, bufferedPositionMs = 5_000))
        assertFalse(policy.observeStall(6_000, waiting = true, bufferedPositionMs = 5_000))
        assertFalse(policy.observeStall(11_999, waiting = true, bufferedPositionMs = 5_000))
        assertTrue(policy.observeStall(12_000, waiting = true, bufferedPositionMs = 5_000))
        // Bildirildikten sonra sayaç baştan.
        assertFalse(policy.observeStall(14_000, waiting = true, bufferedPositionMs = 5_000))
    }

    /** Yavaş ama ilerleyen yükleme takılma değil. */
    @Test
    fun tamponBuyuyorsa_takilmaYok() {
        var buffered = 0L
        for (t in 0L..60_000L step 2_000L) {
            buffered += 100
            assertFalse(policy.observeStall(t, waiting = true, bufferedPositionMs = buffered))
        }
    }

    /** Kullanıcı duraklattıysa ya da parça çalıyorsa sayılmaz. */
    @Test
    fun beklemiyorsa_sayacSifirlanir() {
        policy.observeStall(0, waiting = true, bufferedPositionMs = 5_000)
        policy.observeStall(10_000, waiting = true, bufferedPositionMs = 5_000)
        assertFalse(policy.observeStall(11_000, waiting = false, bufferedPositionMs = 5_000))
        assertFalse(policy.observeStall(13_000, waiting = true, bufferedPositionMs = 5_000))
        assertFalse(policy.observeStall(24_999, waiting = true, bufferedPositionMs = 5_000))
        assertTrue(policy.observeStall(25_000, waiting = true, bufferedPositionMs = 5_000))
    }

    @Test
    fun parcaAkinca_takilmaSayaciSifirlanir() {
        policy.observeStall(0, waiting = true, bufferedPositionMs = 5_000)
        policy.onReady()
        assertFalse(policy.observeStall(12_000, waiting = true, bufferedPositionMs = 5_000))
    }

    // ---- Parça açılamadı -----------------------------------------------------

    /** Tünelde üç parça aynı saniyede atlanıp müzik durmuştu. */
    @Test
    fun agHatasinda_parcaAtlanmaz_agBeklenir() {
        for (retry in 0 until 5) {
            assertEquals(OpenFailure.WAIT_FOR_NETWORK, policy.onOpenFailure(true, retry, skips = 0))
        }
    }

    @Test
    fun agBeklemesiTukenince_sıradakineGecilir() {
        assertEquals(OpenFailure.SKIP, policy.onOpenFailure(true, networkRetries = 5, skips = 0))
    }

    @Test
    fun acilmayanParca_atlanir_sonraVazgecilir() {
        assertEquals(OpenFailure.SKIP, policy.onOpenFailure(false, 0, skips = 0))
        assertEquals(OpenFailure.SKIP, policy.onOpenFailure(false, 0, skips = 1))
        assertEquals(OpenFailure.GIVE_UP, policy.onOpenFailure(false, 0, skips = 2))
    }

    @Test
    fun agHatasiZincirdeAraniyor() {
        val wrapped = RuntimeException("çözümleme", IllegalStateException(UnknownHostException("youtube")))
        assertTrue(RecoveryPolicy.isNetworkError(wrapped))
        assertTrue(RecoveryPolicy.isNetworkError(IOException()))
        assertFalse(RecoveryPolicy.isNetworkError(IllegalStateException("bozuk yanıt")))
    }
}
