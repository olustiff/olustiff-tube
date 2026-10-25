package com.olustiff.app.player

/**
 * Oynatma kurtarma KARARLARI — hepsi tek yerde.
 *
 * Neden ayrı: bu kararlar önce dört ayrı yerde (oynatıcı hatası, takılma
 * bekçisi, sıradakine geçiş, ses çıkışı) kendi durumlarıyla verildi ve
 * birbirini görmedi. Gerçek kullanımda çakıştılar: Bluetooth kopunca
 * odak dönüşü "kesinti bitti" deyip müziği hoparlörden başlattı; hata ve
 * takılma aynı parçayı ayrı ayrı tazeledi.
 *
 * Android'e ve oynatıcıya BAĞIMLI DEĞİL: yalnızca karar veriyor, işi
 * [PlayerHolder] yapıyor. Böylece her karar birim testle sınanıyor
 * (bkz. RecoveryPolicyTest) — yaşanan hataların hiçbiri sessizce geri
 * gelemesin diye.
 *
 * Erişim tek iş parçacığından (ana) bekleniyor; [outputLost] dışarıdan
 * okunabildiği için uçucu.
 */
class RecoveryPolicy(
    private val stallLimitMs: Long = 12_000L,
    private val maxNetworkRetries: Int = 5,
    private val maxSkips: Int = 3
) {

    // ---- Ses çıkışı kilidi -------------------------------------------------

    /**
     * Ses çıkışı (Bluetooth/kulaklık) koptu ve kullanıcı o zamandan beri
     * hiçbir şeye basmadı.
     *
     * Kilitliyken HİÇBİR otomatik mekanizma (odak dönüşü, ağ geri gelince
     * yeniden deneme, takılma bekçisi, adres tazeleme, sıradaki parça) sesi
     * başlatamıyor: arabanın Bluetooth'u kopunca müzik telefonun
     * hoparlöründen çalmaya devam etmişti. Kilidi yalnızca kullanıcının bir
     * komutu ([onUserIntent]) ya da çıkışın geri gelmesi ([onOutputRestored])
     * açıyor.
     */
    @Volatile
    var outputLost = false
        private set

    /**
     * Çıkış koptu. Dönüş: yeni bir olay mı (günlüğe yazılmalı mı). İki kaynak
     * (sistem yayını + cihaz listesi) aynı kopmayı ardışık bildirebiliyor.
     */
    fun onOutputLost(wasPlaying: Boolean): Boolean {
        if (outputLost && !wasPlaying) return false
        outputLost = true
        return true
    }

    /** Kullanıcı bilerek bir şey istedi. Dönüş: kilit kalktı mı. */
    fun onUserIntent(): Boolean {
        if (!outputLost) return false
        outputLost = false
        return true
    }

    /** Çıkış geri geldi (ör. Bluetooth yeniden bağlandı). */
    fun onOutputRestored() {
        outputLost = false
    }

    /**
     * Otomatik bir mekanizma çalmayı başlatmak istiyor: izin var mı.
     * [wanted] çağıranın kendi isteği (ör. "hata anında çalıyor muydu").
     */
    fun mayAutoStart(wanted: Boolean = true): Boolean = wanted && !outputLost

    // ---- Adres tazeleme hakkı ----------------------------------------------

    private var refreshedFor: String? = null

    /**
     * Parçanın adreslerini tazeleme hakkını kullanır.
     *
     * Parça başına BİR KEZ ve hata ile takılma AYNI hakkı paylaşıyor:
     * tazelenmiş adres de çalışmıyorsa sorun adreste değildir (video
     * açılamıyor ya da ağ yok) ve tekrar tekrar çözümlemek sonsuz döngü olur.
     * Hak, parça akmaya başlayınca ([onReady]) yenileniyor.
     */
    fun claimRefresh(videoId: String): Boolean {
        if (refreshedFor == videoId) return false
        refreshedFor = videoId
        return true
    }

    /** Parça akıyor: takılma sayacı sıfır, tazeleme hakkı yenilendi. */
    fun onReady() {
        refreshedFor = null
        stuckSince = null
    }

    /**
     * Oynatıcı hatası adres tazelemeyle düzelir mi: yalnızca giriş/çıkış
     * (ağ, HTTP) hataları. Kod çözücü hatası tazelemeyle düzelmez.
     * Kodlar Media3'ün `PlaybackException.ERROR_CODE_IO_*` aralığı.
     */
    fun isRefreshable(errorCode: Int): Boolean = errorCode in IO_ERROR_FIRST..IO_ERROR_LAST

    // ---- Adresin süresi ------------------------------------------------------

    /**
     * Akış adresinin süresi dolmuş ya da dolmak üzere mi.
     *
     * YouTube adresleri ~6 saat geçerli. Günlükte (25 Ekim) görülen: uzun bir
     * video sabah duraklatıldı, akşam sürdürüldü; adres 8 saatlikti ve her
     * istek 403 aldı. Oynatıcı ~50 sn boyunca 17 kez deneyip ancak sonra hata
     * verdi, adres tazelendi, bir 34 sn de açılış bekledi. Süre adresin
     * içinde yazılı (`expire`), yani ÇALMADAN ÖNCE bilinebiliyor.
     *
     * @param expireEpochSec adresteki `expire`; bilinmiyorsa null (ör. canlı yayın)
     */
    fun isExpiring(expireEpochSec: Long?, nowEpochSec: Long): Boolean =
        expireEpochSec != null && nowEpochSec >= expireEpochSec - EXPIRY_MARGIN_SEC

    // ---- Takılma -------------------------------------------------------------

    private var lastBuffered = -1L
    /** Tamponun son büyüdüğü an; null: bekleme yok. */
    private var stuckSince: Long? = null

    /**
     * Takılma bekçisinin her turunda çağrılır.
     *
     * Takılma: çalması gereken oynatıcı ([waiting]) tamponunu [stallLimitMs]
     * boyunca HİÇ büyütemedi. Oynatıcı zaman aşımlarını kendi içinde sessizce
     * yeniden denediği için bu durumda hata bildirilmiyor; cihazda ~50 sn
     * donma olarak ölçüldü.
     *
     * Dönüş true ise takılma var; sayaç sıfırlanır (bir sonraki bildirim en
     * erken [stallLimitMs] sonra).
     */
    fun observeStall(nowMs: Long, waiting: Boolean, bufferedPositionMs: Long): Boolean {
        if (!waiting) {
            stuckSince = null
            return false
        }
        val since = stuckSince
        if (since == null || bufferedPositionMs != lastBuffered) {
            lastBuffered = bufferedPositionMs
            stuckSince = nowMs
            return false
        }
        if (nowMs - since < stallLimitMs) return false
        stuckSince = null
        return true
    }

    // ---- Parça açılamadı -----------------------------------------------------

    enum class OpenFailure {
        /** Ağ yok: ağ gelene kadar bekleyip AYNI parçayı yeniden dene. */
        WAIT_FOR_NETWORK,

        /** Bu parça açılmıyor: sıradakine geç. */
        SKIP,

        /** Art arda çok parça açılmadı: dur. */
        GIVE_UP
    }

    /**
     * Bir parça (ya da tazelenen adres) açılamadığında ne yapılacağı.
     *
     * AĞ HATASINDA PARÇA ATLANMIYOR: tünelde/çekmeyen yolda üç parça aynı
     * saniyede denenip "açılabilen parça yok" denmiş ve ağ gelince de müzik
     * başlamamıştı. Ağ yoksa sıradaki de açılmaz; atlamak yalnızca şarkı
     * kaybettirir.
     *
     * @param networkRetries bu parça için şimdiye kadar yapılmış ağ beklemesi
     * @param skips bu ilerlemede şimdiye kadar atlanmış parça
     */
    fun onOpenFailure(isNetworkError: Boolean, networkRetries: Int, skips: Int): OpenFailure =
        when {
            isNetworkError && networkRetries < maxNetworkRetries -> OpenFailure.WAIT_FOR_NETWORK
            skips + 1 < maxSkips -> OpenFailure.SKIP
            else -> OpenFailure.GIVE_UP
        }

    companion object {
        // PlaybackException.ERROR_CODE_IO_UNSPECIFIED .. ERROR_CODE_IO_NO_PERMISSION
        // (sabitler burada tekrar yazılıyor ki sınıf Media3'e bağlanmasın;
        // eşitlikleri RecoveryPolicyTest'te sınanıyor).
        const val IO_ERROR_FIRST = 2000
        const val IO_ERROR_LAST = 2006

        /** Süresine bu kadar kalmış adres de tazelenir: çalarken dolmasın. */
        const val EXPIRY_MARGIN_SEC = 10 * 60L

        /** Hata zincirinde bir ağ (G/Ç) hatası var mı. */
        fun isNetworkError(e: Throwable): Boolean =
            generateSequence(e) { it.cause }.take(8).any { it is java.io.IOException }
    }
}
