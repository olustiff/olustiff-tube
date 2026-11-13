package com.olustiff.app

import android.content.Context
import java.util.Locale

/**
 * Native tarafta üretilen metinlerin (bildirimler, hata iletileri) dili.
 *
 * Dart tarafındaki `Lang` ile aynı seçimi kullanıyor: arayüz dili değişince
 * `olustiff/ui` kanalından `setLanguage` geliyor. Uygulama arayüzü hiç
 * açılmadan başlayan servisler (Bluetooth otomatik çalma, TV yayın alıcısı)
 * için [init] kayıtlı seçimi Flutter'ın tercih dosyasından okuyor.
 */
object Lang {
    @Volatile
    var english: Boolean = Locale.getDefault().language != "tr"
        private set

    fun init(context: Context) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        english = when (prefs.getString("flutter.app_language", "system")) {
            "turkish" -> false
            "english" -> true
            else -> Locale.getDefault().language != "tr"
        }
    }

    fun set(code: String) {
        english = code == "en"
    }

    /** Metni dile göre seçer: `tr("Oynatılıyor", "Playing")`. */
    fun tr(turkish: String, english: String): String = if (this.english) english else turkish
}
