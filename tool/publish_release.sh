#!/bin/zsh
# Sürüm yayınlar: mimariye özel APK'lar + ortak APK.
#
# Neden üç dosya: tek "universal" APK üç mimarinin kodunu birden taşıyor
# (~53 MB), cihaz ise yalnızca birini kullanıyor. Uygulama içi güncelleme
# kendi mimarisine uyanı indiriyor (~21 MB). Ortak dosya, hem sabit indirme
# linki (releases/latest/download/olustiff.apk) hem de tanınmayan mimariler
# için yedek olarak duruyor.
#
# Kullanım: tool/publish_release.sh <sürüm> <notlar-dosyası>
set -e

VERSION="$1"
NOTES_FILE="$2"
# Sürümler kod deposunda (olustiff/olustiff-tube). Eski sürüm deposu
# (olustiff/youtube) GEÇİŞ için ayna: kurulu uygulamalar güncellemeyi hâlâ
# orada arıyor ve yeni adresi ancak onu içeren bir sürümü kurunca öğreniyor.
# Cihazlar yeni adrese geçince AYNA boşaltılıp eski depo arşivlenebilir.
DEPOLAR=("olustiff/olustiff-tube" "olustiff/youtube")
APP_DIR="${0:a:h}/.."

if [ -z "$VERSION" ] || [ ! -f "$NOTES_FILE" ]; then
  echo "kullanım: tool/publish_release.sh <sürüm> <notlar-dosyası>" >&2
  exit 1
fi

cd "$APP_DIR"

# Yayın adı ile uygulamanın kendi sürümü aynı olmalı: uygulama içi güncelleme
# ikisini karşılaştırıyor. Farklıysa kurulu uygulama kendini hep "eski"
# sanıp aynı sürümü tekrar tekrar öneriyor.
PUBSPEC_VERSION=$(grep -E '^version:' pubspec.yaml | sed -E 's/version: *([^+]*).*/\1/')
if [ "$PUBSPEC_VERSION" != "$VERSION" ]; then
  echo "HATA: pubspec.yaml sürümü $PUBSPEC_VERSION, yayınlanmak istenen $VERSION." >&2
  exit 1
fi

# Mac'teki yollar varsayılan; otomatik bakım (GitHub Actions) kendi yollarını
# önceden veriyor.
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

echo "== derleniyor =="
flutter build apk --release --split-per-abi > /dev/null
flutter build apk --release > /dev/null

OUT="build/app/outputs/flutter-apk"

# İmza denetimi: kurulu uygulamalar tek bir anahtarla imzalı; başka anahtarla
# imzalanmış bir güncelleme telefonda kurulmaz. Yayından ÖNCE yakalanmalı —
# yayınlandıktan sonra herkese kurulamayan bir güncelleme önerilmiş olur.
BEKLENEN_IMZA="6994909a09b3d158e1377ca7b8cb86dfb71eb9355deef4cce062ca097c53a90a"
IMZACI=$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)apksigner
for apk in app-arm64-v8a-release.apk app-armeabi-v7a-release.apk app-release.apk; do
  imza=$("$IMZACI" verify --print-certs "$OUT/$apk" | grep -m1 'SHA-256' | awk '{print $NF}')
  if [ "$imza" != "$BEKLENEN_IMZA" ]; then
    echo "HATA: $apk yanlış anahtarla imzalı ($imza). Yayın yapılmadı." >&2
    exit 1
  fi
done
echo "== imza doğru =="
STAGE=$(mktemp -d)
cp "$OUT/app-arm64-v8a-release.apk"   "$STAGE/olustiff-arm64.apk"
cp "$OUT/app-armeabi-v7a-release.apk" "$STAGE/olustiff-arm32.apk"
cp "$OUT/app-release.apk"             "$STAGE/olustiff.apk"

# Her depoya: TASLAK olarak açılıyor, dosyalar yüklendikten SONRA
# yayınlanıyor. Doğrudan yayınlanınca uygulamalar dosyalar yüklenirken yeni
# sürümü görüyor, eksik APK'yı indirmeye çalışıp hata veriyordu.
TOKEN="${GH_TOKEN:-$(gh auth token)}"

yayinla_depo() {
  local REPO="$1"
  echo "== taslak oluşturuluyor: $REPO v$VERSION =="
  gh release create "v$VERSION" --repo "$REPO" --draft \
    --title "oLusTifF $VERSION" --notes-file "$NOTES_FILE"
  local RID
  RID=$(gh release view "v$VERSION" --repo "$REPO" --json databaseId --jq .databaseId)

  # gh release upload büyük dosyalarda aralıklı olarak HTTP 400 veriyor;
  # doğrudan yükleme uç noktası daha güvenilir çalışıyor.
  for name in olustiff-arm64.apk olustiff-arm32.apk olustiff.apk; do
    echo "== yükleniyor: $name =="
    local uploaded=0 code
    for attempt in 1 2 3; do
      code=$(curl --progress-bar -o /dev/null -w '%{http_code}' --max-time 1800 \
        -X POST -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/vnd.android.package-archive" \
        --data-binary "@$STAGE/$name" \
        "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$name") \
        || code="000"  # ağ hatası: set -e betiği burada öldürmesin, yeniden denensin
      if [ "$code" = "201" ]; then
        echo "   tamam"
        uploaded=1
        break
      fi
      echo "   HTTP $code, yeniden deneniyor"
      sleep 5
    done
    if [ "$uploaded" != 1 ]; then
      echo "HATA: $name ($REPO) yüklenemedi. Sürüm TASLAK olarak bırakıldı;" >&2
      echo "GitHub'dan elle tamamlayın ya da silip yeniden çalıştırın." >&2
      rm -rf "$STAGE"
      exit 1
    fi
  done

  echo "== yayınlanıyor: $REPO =="
  gh release edit "v$VERSION" --repo "$REPO" --draft=false
  gh release view "v$VERSION" --repo "$REPO" --json assets \
    --jq '.assets[] | "\(.name)  \(.size/1048576|floor)MB  \(.state)"'
}

for depo in "${DEPOLAR[@]}"; do
  yayinla_depo "$depo"
done
rm -rf "$STAGE"
