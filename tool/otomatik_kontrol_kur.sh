#!/bin/zsh
# YouTube çözümleyicisi için haftalık otomatik kontrolü kurar (ya da kaldırır).
#
# ## Neden macOS'un kendi zamanlayıcısı
#
# Kontrolün bütün değeri UNUTULMADAN yapılmasında. Terminalin açık kalmasına,
# bir oturumun sürmesine ya da birinin hatırlamasına bağlı her çözüm, ilk
# unutulduğunda değerini kaybediyor. launchd makine açıkken kendi kendine
# çalışıyor ve kapalıyken kaçırdığı çalıştırmayı açılışta telafi ediyor.
#
# ## Neden kontrol betiği projenin DIŞINA kopyalanıyor
#
# Proje `~/Desktop` altında ve macOS orayı koruyor: arka plan işleri Masaüstü,
# Belgeler ve İndirilenler klasörlerini Tam Disk Erişimi olmadan okuyamıyor.
# İlk denemede launchd işi tam olarak buna takıldı ("can't open input file")
# ve sessizce başarısız oldu. Kopya `~/Library/Application Support` altında
# duruyor; orası korumalı değil.
#
# Bu yüzden kontrol projeden BAĞIMSIZ çalışıyor: bizdeki sürümü okumuyor,
# "NewPipeExtractor en son ne yayınladı" sorusunu soruyor ve cevap bir önceki
# kontrolden farklıysa haber veriyor. Zaten bilmek istediğimiz şey bu.
#
# Kullanım:
#   tool/otomatik_kontrol_kur.sh          # kurar
#   tool/otomatik_kontrol_kur.sh --kaldir
set -e

ETIKET="com.olustiff.extractor-kontrol"
PLIST="$HOME/Library/LaunchAgents/$ETIKET.plist"
EV="$HOME/Library/Application Support/olustiff"
KONTROL="$EV/surum_kontrol.sh"

if [ "$1" = "--kaldir" ]; then
  launchctl bootout "gui/$(id -u)/$ETIKET" 2>/dev/null || true
  rm -f "$PLIST" "$KONTROL"
  echo "Otomatik kontrol kaldırıldı."
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$EV"

cat > "$KONTROL" <<'KONTROLSON'
#!/bin/zsh
# NewPipeExtractor'ın son yayınına bakar; bir öncekinden farklıysa haber verir.
# Bu dosya `tool/otomatik_kontrol_kur.sh` tarafından üretiliyor, elle
# düzenlemeyin — kurulum her çalıştığında üzerine yazılır.
set -e
EV="$HOME/Library/Application Support/olustiff"
GUNLUK="$HOME/Library/Logs/olustiff-extractor.log"
SON_GORULEN="$EV/son_gorulen"
tarih=$(date '+%Y-%m-%d %H:%M')

son=$(gh api "repos/TeamNewPipe/NewPipeExtractor/releases" \
  --jq '[.[] | select(.draft == false and .prerelease == false)] | .[0].tag_name' 2>/dev/null) || son=""

if [ -z "$son" ]; then
  echo "$tarih  sorulamadi (gh oturumu?)" >> "$GUNLUK"
  exit 0
fi

onceki=$(cat "$SON_GORULEN" 2>/dev/null || echo "")
echo "$son" > "$SON_GORULEN"

if [ "$onceki" = "$son" ]; then
  echo "$tarih  degisiklik yok ($son)" >> "$GUNLUK"
  exit 0
fi

# İlk çalıştırmada bildirim YOK: o an görülen sürüm "yeni" değil, sadece
# başlangıç noktası. Aksi halde kurulumun hemen ardından yanıltıcı bir
# bildirim düşerdi.
if [ -z "$onceki" ]; then
  echo "$tarih  baslangic ($son)" >> "$GUNLUK"
  exit 0
fi

echo "$tarih  YENI YAYIN: $onceki -> $son" >> "$GUNLUK"
osascript -e "display notification \"NewPipeExtractor $son yayınlandı. Güncellemek için: tool/extractor_guncelle.sh --uygula\" with title \"oLusTifF — çözümleyici güncellemesi\" sound name \"Ping\"" 2>/dev/null || true
KONTROLSON

chmod +x "$KONTROL"

# PATH açıkça yazılıyor: launchd işleri kullanıcının kabuk ayarlarını okumuyor
# ve `gh` varsayılan PATH'te yok — yazılmazsa iş sessizce başarısız olur.
cat > "$PLIST" <<PLISTSON
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$ETIKET</string>

  <key>ProgramArguments</key>
  <array>
    <string>$KONTROL</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <!-- Pazartesi 10:07. Tam saat başı DEĞİL: yuvarlak dakikalarda herkes aynı
       anda istek atıyor ve bu kontrolün birkaç dakika kayması hiçbir şey
       değiştirmiyor. -->
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>1</integer>
    <key>Hour</key><integer>10</integer>
    <key>Minute</key><integer>7</integer>
  </dict>

  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/olustiff-extractor-hata.log</string>
</dict>
</plist>
PLISTSON

launchctl bootout "gui/$(id -u)/$ETIKET" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Kuruldu: her pazartesi 10:07'de çözümleyicinin son yayınına bakılacak."
echo "Yeni sürüm çıkarsa ekrana bildirim düşer."
echo
echo "Günlük   : ~/Library/Logs/olustiff-extractor.log"
echo "Kaldırmak: tool/otomatik_kontrol_kur.sh --kaldir"
echo "Hemen denemek: launchctl kickstart gui/$(id -u)/$ETIKET"
