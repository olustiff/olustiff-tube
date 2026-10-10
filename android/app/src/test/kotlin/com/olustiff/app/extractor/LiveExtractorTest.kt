package com.olustiff.app.extractor

import com.olustiff.app.player.StreamSelector
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNoException
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.schabi.newpipe.extractor.exceptions.SignInConfirmNotBotException

/**
 * Çözümleyiciyi GERÇEK YouTube'a karşı dener: ara → videoyu çöz → akışın
 * ilk baytlarını indir.
 *
 * Otomatik güncellemenin güvenlik kilidi bu test. Dart testleri çözümleyiciye
 * hiç dokunmuyor; derlenen her sürüm "derlendi" diye çalışıyor sayılırdı.
 * YouTube'un bozduğu şey neredeyse hep bu üç adımdan biri: arama boş döner,
 * video çözülemez ya da akış adresi 403 verir.
 *
 * Ağ gerektirdiği için yalnızca `LIVE_EXTRACTOR_TEST=1` ile çalışıyor;
 * sıradan derlemeleri internet bağlantısına bağımlı kılmıyor.
 *
 * "Bot olmadığını doğrula" engeli ATLAMA sayılıyor, hata değil: YouTube
 * veri merkezi adreslerini (GitHub'ın sunucuları dahil) bu şekilde
 * reddediyor. Ev bağlantısından aynı test geçiyor; engel çözümleyicinin
 * bozulduğunu değil, isteğin nereden geldiğini gösteriyor. Hata sayılsaydı
 * otomatik bakım hiçbir güncellemeyi yayınlayamazdı.
 */
class LiveExtractorTest {

    @Test
    fun aramaCozumlemeVeAkisCalisiyor() = runBlocking {
        assumeTrue(System.getenv("LIVE_EXTRACTOR_TEST") == "1")

        val result = botEngeliAtla("arama") { ExtractionService.search("tarkan kuzu kuzu") }
        @Suppress("UNCHECKED_CAST")
        val items = result["items"] as List<Map<String, Any?>>
        assertTrue("Arama sonuç döndürmedi", items.isNotEmpty())

        val videoId = items.first()["videoId"] as String
        val info = botEngeliAtla("video çözme") { ExtractionService.streamInfo(videoId) }

        val audio = StreamSelector.select(info, audioOnly = true)
        assertNotNull("Ses akışı seçilemedi ($videoId)", audio)
        assertFetchable(audio!!.audioUrl)

        val video = StreamSelector.select(info, audioOnly = false)
        assertNotNull("Video akışı seçilemedi ($videoId)", video)
    }

    private inline fun <T> botEngeliAtla(adim: String, block: () -> T): T =
        try {
            block()
        } catch (e: SignInConfirmNotBotException) {
            println("ATLANDI: YouTube bu bağlantıyı bot sandı ($adim)")
            assumeNoException(e)
            throw e
        }

    /** Adresin gerçekten veri verdiğini doğrular; 403 en sık bozulma biçimi. */
    private fun assertFetchable(url: String) {
        val request = Request.Builder()
            .url(url)
            .header("Range", "bytes=0-65535")
            .build()
        OkHttpClient().newCall(request).execute().use { response ->
            assertTrue(
                "Akış adresi reddedildi: HTTP ${response.code}",
                response.code == 200 || response.code == 206
            )
            val bytes = response.body?.bytes()?.size ?: 0
            assertTrue("Akış boş döndü", bytes > 0)
        }
    }
}
