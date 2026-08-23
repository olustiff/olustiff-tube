package com.olustiff.app.player

import android.graphics.SurfaceTexture
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * ExoPlayer'ın video çıktısını Flutter'ın doku (texture) katmanına bağlar.
 *
 * Neden PlatformView değil: `AndroidView` ile gömülen bir PlayerView, Flutter'ın
 * sanal ekran / hibrit kompozisyon yollarında cihazdan cihaza farklı davranıyor
 * ve bazı gerçek cihazlarda siyah kare olarak çiziliyor. Flutter'ın kendi
 * `Texture` widget'ı ise her yerde aynı şekilde çalışır: burada ExoPlayer
 * doğrudan Flutter'ın sağladığı [SurfaceTexture]'a render eder.
 *
 * Yüzey, video ekranı açıkken bağlanır ve kapanınca ayrılır; player'a
 * dokunulmaz, bu yüzden ses arka planda kesintisiz devam eder.
 */
class VideoTextureBridge(private val textureRegistry: TextureRegistry) {

    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null

    /** Doku oluşturur (ya da mevcudu döner) ve player'ın çıktısını ona bağlar. */
    fun attach(): Long {
        val existing = entry
        if (existing != null) {
            PlayerHolder.setVideoSurface(surface)
            return existing.id()
        }

        val created = textureRegistry.createSurfaceTexture()
        entry = created

        val texture: SurfaceTexture = created.surfaceTexture()
        val newSurface = Surface(texture)
        surface = newSurface

        PlayerHolder.setVideoSurface(newSurface)
        return created.id()
    }

    /**
     * Video ekranı kapandığında çağrılır. Player DURDURULMAZ — yalnızca video
     * çıktısı serbest bırakılır, ses akmaya devam eder.
     */
    fun detach() {
        PlayerHolder.setVideoSurface(null)
        surface?.release()
        surface = null
        entry?.release()
        entry = null
    }

    /** Video boyutunu Flutter'a bildirmek için son bilinen en/boy oranı. */
    fun currentAspectRatio(): Double = PlayerHolder.videoAspectRatio
}
