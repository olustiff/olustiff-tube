package com.utkuhalis.akis.player

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import androidx.media3.ui.PlayerView
import com.utkuhalis.akis.R
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Flutter widget ağacına gömülen video yüzeyi.
 *
 * Sadece bir "pencere"dir: player'a sahip değildir, [PlayerHolder]'daki ortak
 * örneğe bağlanır. [dispose] çağrıldığında player DURDURULMAZ, yalnızca yüzey
 * ayrılır — kullanıcı video ekranından çıktığında ses arka planda akmaya devam
 * eder.
 *
 * Görünüm XML'den şişiriliyor çünkü PlayerView'ın TextureView kullanması
 * yalnızca XML özniteliğiyle ayarlanabiliyor (bkz. res/layout/player_view.xml).
 */
class PlayerPlatformView(context: Context) : PlatformView {

    private val playerView: PlayerView =
        LayoutInflater.from(context).inflate(R.layout.player_view, null) as PlayerView

    init {
        playerView.player = PlayerHolder.getPlayer(context)
    }

    override fun getView(): View = playerView

    override fun dispose() {
        // Player bilerek release EDİLMİYOR — arka planda oynatma devam etsin.
        playerView.player = null
    }
}

class PlayerPlatformViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        PlayerPlatformView(context)
}
