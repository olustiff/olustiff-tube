<p align="center">
  <img src="assets/logo.png" width="120" alt="oLusTifF logo">
</p>

<h1 align="center">oLusTifF</h1>

<p align="center">
  <b>Free, ad-free YouTube client for Android phones and Android TV</b><br>
  <b>Android telefon ve Android TV için ücretsiz, reklamsız YouTube istemcisi</b>
</p>

<p align="center">
  <a href="https://github.com/olustiff/olustiff-tube/releases/latest/download/olustiff.apk"><b>⬇ Download APK / APK'yı indir</b></a>
  ·
  <a href="https://github.com/olustiff/olustiff-tube/releases">Releases / Sürümler</a>
  ·
  <a href="#türkçe">Türkçe</a>
</p>

---

## English

oLusTifF is an open-source YouTube player for Android. It plays YouTube videos and
music **without ads**, **without an account** and **without tracking**, keeps
playing in the background with the screen off, and works on **Android TV** with
the remote control.

### Features

- **No ads** — videos and music start straight away, no pre-roll or banner ads
- **Background play** — music keeps playing with the screen off or in another app
- **Audio-only mode** — listen to music without downloading the video (saves data and battery)
- **Android TV** — full remote-control interface, voice search, cast from your phone to the TV
- **Picture-in-picture** — keep watching in a small window
- **MP3 download** — save songs to your phone
- **Automatic quality** — adapts to your connection, or pick a fixed resolution
- **Queue, autoplay, repeat, shuffle, sleep timer, playlists**
- **Favourites** (♥) and **most played** lists, kept on your device only
- **Bluetooth / car** — resumes when your headphones or car connect; never jumps to the phone speaker when Bluetooth drops
- **No Google account, no sign-in, no tracking** — your history never leaves the device
- **In-app updates** from this repository's releases

### Install

1. Download [`olustiff.apk`](https://github.com/olustiff/olustiff-tube/releases/latest/download/olustiff.apk) on your phone or TV
2. Open it and allow installing from this source when Android asks
3. Updates are offered inside the app (Settings → Check for updates)

Smaller per-device builds (`olustiff-arm64.apk`, `olustiff-arm32.apk`) are on the
[releases page](https://github.com/olustiff/olustiff-tube/releases). Most phones use arm64;
most TVs and TV boxes use arm32.

### Build from source

Flutter (Dart) app with a native Kotlin player
([Media3 / ExoPlayer](https://developer.android.com/media/media3)). YouTube
streams are extracted with [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor).

```sh
flutter pub get
flutter test
flutter build apk --release
```

---

## Türkçe

oLusTifF, Android için açık kaynaklı bir YouTube oynatıcısı. YouTube videolarını ve
müziklerini **reklamsız**, **hesapsız** ve **takipsiz** oynatır. Ekran kapalıyken
arka planda çalmaya devam eder ve **Android TV**'de kumandayla çalışır.

### Özellikler

- **Reklam yok**: videolar ve müzikler hemen başlar, ne başta ne arada reklam var
- **Arka planda çalma**: ekran kapalıyken ya da başka uygulamadayken müzik devam eder
- **Sadece ses modu**: müziği görüntüyü indirmeden dinle (internet ve pil tasarrufu)
- **Android TV**: kumandayla tam kullanım, sesli arama, telefondan televizyona gönderme
- **Resim içinde resim**: küçük pencerede izlemeye devam et
- **MP3 indirme**: şarkıları telefona kaydet
- **Otomatik kalite**: internet hızına göre ayarlanır ya da sabit çözünürlük seç
- **Sıra, otomatik oynatma, tekrar, karıştırma, uyku zamanlayıcısı, çalma listeleri**
- **Favoriler** (♥) ve **en çok dinlenenler**: yalnızca cihazında saklanır
- **Bluetooth / araba**: kulaklık ya da araba bağlanınca kaldığı yerden devam eder; Bluetooth kopunca müzik telefonun hoparlöründen başlamaz
- **Google hesabı yok, giriş yok, takip yok**: geçmişin cihazından çıkmaz
- **Uygulama içinden güncelleme**

### Kurulum

1. Telefonundan ya da televizyonundan [`olustiff.apk`](https://github.com/olustiff/olustiff-tube/releases/latest/download/olustiff.apk) dosyasını indir
2. Aç ve Android sorduğunda bu kaynaktan yüklemeye izin ver
3. Güncellemeler uygulamanın içinden gelir (Ayarlar → Güncellemeleri denetle)

Cihaza özel daha küçük dosyalar (`olustiff-arm64.apk`, `olustiff-arm32.apk`)
[sürümler sayfasında](https://github.com/olustiff/olustiff-tube/releases). Telefonların
çoğu arm64, televizyon ve TV kutularının çoğu arm32 kullanır.

### Öneri ve hata bildirimi

[Issues](https://github.com/olustiff/olustiff-tube/issues) sayfasından yazabilirsin.

---

## License / Lisans

[GPL-3.0](LICENSE). oLusTifF is not affiliated with, endorsed by or sponsored by
YouTube or Google. / oLusTifF'in YouTube ya da Google ile hiçbir bağlantısı yoktur.
