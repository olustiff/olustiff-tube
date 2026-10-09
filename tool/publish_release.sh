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
REPO="olustiff/youtube"
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

export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"

echo "== derleniyor =="
flutter build apk --release --split-per-abi > /dev/null
flutter build apk --release > /dev/null

OUT="build/app/outputs/flutter-apk"
STAGE=$(mktemp -d)
cp "$OUT/app-arm64-v8a-release.apk"   "$STAGE/olustiff-arm64.apk"
cp "$OUT/app-armeabi-v7a-release.apk" "$STAGE/olustiff-arm32.apk"
cp "$OUT/app-release.apk"             "$STAGE/olustiff.apk"

# TASLAK olarak açılıyor, dosyalar yüklendikten SONRA yayınlanıyor. Doğrudan
# yayınlanınca uygulamalar dosyalar yüklenirken yeni sürümü görüyor, eksik
# APK'yı indirmeye çalışıp hata veriyordu.
echo "== taslak oluşturuluyor: v$VERSION =="
gh release create "v$VERSION" --repo "$REPO" --draft \
  --title "oLusTifF $VERSION" --notes-file "$NOTES_FILE"

RID=$(gh release view "v$VERSION" --repo "$REPO" --json databaseId --jq .databaseId)
TOKEN=$(gh auth token)

# gh release upload büyük dosyalarda aralıklı olarak HTTP 400 veriyor;
# doğrudan yükleme uç noktası daha güvenilir çalışıyor.
# x86_64 ayrica yayinlanmiyor: yalnizca emulatorlerde kullaniliyor ve
# ortak dosya zaten onu da tasiyor.
for name in olustiff-arm64.apk olustiff-arm32.apk olustiff.apk; do
  echo "== yükleniyor: $name =="
  uploaded=0
  for attempt in 1 2 3; do
    # --progress-bar: yukleme ilerlemesi gorunur olsun (-s onu susturuyordu).
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
    echo "HATA: $name yüklenemedi. Sürüm TASLAK olarak bırakıldı;" >&2
    echo "GitHub'dan elle tamamlayın ya da silip yeniden çalıştırın." >&2
    rm -rf "$STAGE"
    exit 1
  fi
done

rm -rf "$STAGE"
echo "== yayınlanıyor =="
gh release edit "v$VERSION" --repo "$REPO" --draft=false
gh release view "v$VERSION" --repo "$REPO" --json assets \
  --jq '.assets[] | "\(.name)  \(.size/1048576|floor)MB  \(.state)"'
