#!/bin/zsh
# YouTube çözümleyicisini (NewPipeExtractor) günceller.
#
# ## Neden ayrı bir araç
#
# Uygulamanın YouTube'la konuşan tek parçası bu kütüphane. YouTube arayüzünü
# değiştirdiğinde video açılmaz, arama boş döner ya da akış adresleri
# reddedilir — ve çare tek: kütüphanenin yeni sürümü. Yani bu bağımlılık
# "ara sıra bakılacak" bir şey değil, uygulamanın çalışmaya devam etmesinin
# şartı.
#
# ## Ne yapar, ne YAPMAZ
#
# Yapar: son sürümü sorar, bizdekiyle karşılaştırır, yenisi varsa sürümü
# yükseltir, derler ve testleri koşar.
#
# YAPMAZ: yayınlamaz. Bu bilerek böyle — yayınlamak kullanıcıların cihazına
# giden tek yönlü bir adım ve bir makinenin kendi başına vermesi gereken bir
# karar değil. Her şey yeşilse son satırda yayın komutunu yazar, çalıştırmaz.
#
# Kullanım:
#   tool/extractor_guncelle.sh            # yalnızca bakar, ekrana yazar
#   tool/extractor_guncelle.sh --uygula   # yenisi varsa yükseltir + derler + test eder
#   tool/extractor_guncelle.sh --bildir   # haftalık otomatik kontrol için (bkz. aşağısı)
#
# ## Otomatik kontrol
#
# `--bildir` kipi macOS'un zamanlayıcısı (launchd) tarafından çağrılmak üzere:
# sessiz çalışır, sonucu günlüğe yazar ve YALNIZCA yeni sürüm varsa ekrana
# bildirim düşürür. Kurulumu `tool/otomatik_kontrol_kur.sh` yapıyor.
#
# Neden launchd: kontrolün değeri "unutulmadan" yapılmasında. Terminal açık
# olmasına, bir oturumun sürmesine bağlı bir çözüm ilk unutulduğunda değerini
# kaybeder; launchd makine açıldığında kendi kendine çalışır.
set -e

APP_DIR="${0:a:h}/.."
cd "$APP_DIR"

GRADLE="android/app/build.gradle.kts"
REPO="TeamNewPipe/NewPipeExtractor"

mevcut=$(grep -oE 'NewPipeExtractor:v[0-9]+\.[0-9]+\.[0-9]+' "$GRADLE" | head -1 | sed 's/.*://')
if [ -z "$mevcut" ]; then
  echo "HATA: $GRADLE içinde NewPipeExtractor sürümü bulunamadı." >&2
  exit 1
fi

# Taslak ve ön sürümler elenir: uygulamayı kararlı olmayan bir çözümleyiciye
# bağlamak, çözmeye çalıştığımız sorunun daha kötüsünü getirir.
son=$(gh api "repos/$REPO/releases" \
  --jq '[.[] | select(.draft == false and .prerelease == false)] | .[0].tag_name' 2>/dev/null)
if [ -z "$son" ]; then
  echo "HATA: Son sürüm sorulamadı (gh oturumu açık mı?)." >&2
  exit 1
fi

GUNLUK="$HOME/Library/Logs/olustiff-extractor.log"

if [ "$1" = "--bildir" ]; then
  tarih=$(date '+%Y-%m-%d %H:%M')
  if [ "$mevcut" = "$son" ]; then
    echo "$tarih  guncel ($mevcut)" >> "$GUNLUK"
    exit 0
  fi
  echo "$tarih  YENI SURUM: $mevcut -> $son" >> "$GUNLUK"
  osascript -e "display notification \"YouTube çözümleyicisinin yeni sürümü çıktı: $son (bizdeki $mevcut)\" with title \"oLusTifF\" sound name \"Ping\"" 2>/dev/null || true
  exit 0
fi

echo "bizdeki : $mevcut"
echo "son     : $son"

if [ "$mevcut" = "$son" ]; then
  echo "Güncel — yapılacak bir şey yok."
  exit 0
fi

echo "YENİ SÜRÜM VAR: $mevcut → $son"

if [ "$1" != "--uygula" ]; then
  echo
  echo "Uygulamak için: tool/extractor_guncelle.sh --uygula"
  exit 0
fi

export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"

echo "== sürüm yükseltiliyor =="
sed -i '' "s/NewPipeExtractor:$mevcut/NewPipeExtractor:$son/" "$GRADLE"

# Geri alma, hatanın her türünde çalışsın diye tuzağa bağlanıyor: yarım
# kalmış bir sürüm yükseltmesi, hiç denememekten kötü.
geri_al() {
  echo "BAŞARISIZ — sürüm geri alınıyor ($son → $mevcut)" >&2
  sed -i '' "s/NewPipeExtractor:$son/NewPipeExtractor:$mevcut/" "$GRADLE"
}
trap geri_al ERR

echo "== testler =="
flutter test > /dev/null

echo "== derleme =="
flutter build apk --release --target-platform android-arm64 > /dev/null

trap - ERR
echo
echo "TAMAM: $son ile derlendi ve testler geçti."
echo
echo "Sırada — gerçek cihazda dene, sonra yayınla:"
echo "  adb install -r build/app/outputs/flutter-apk/app-release.apk"
echo "  tool/publish_release.sh <yeni-sürüm> <notlar-dosyası>"
