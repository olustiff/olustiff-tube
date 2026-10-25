#!/bin/zsh
# İmza anahtarının ŞİFRELİ yedeğini çıkarır.
#
# Neden: telefon ve TV'deki uygulama yalnızca aynı anahtarla imzalanmış
# güncellemeyi kabul ediyor. Anahtar (~/.android/debug.keystore) kaybolursa
# uygulama bir daha GÜNCELLENEMEZ; kaldırıp yeniden kurmak gerekir (kayıtlı
# her şey gider). GitHub'daki kopya geri okunamıyor, yani tek başına yedek
# sayılmaz.
#
# Kullanım: tool/anahtar_yedekle.sh [çıktı-dosyası]
# Çıkan dosyayı Mac DIŞINDA bir yere koy (Drive, USB bellek). Şifreyi unutma:
# şifresiz yedek açılamaz.
#
# Geri yükleme:
#   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
#     -in olustiff-imza-anahtari.yedek -out ~/.android/debug.keystore
set -e

KEYSTORE="$HOME/.android/debug.keystore"
OUT="${1:-$HOME/Desktop/olustiff-imza-anahtari.yedek}"
BEKLENEN_IMZA="6994909a09b3d158e1377ca7b8cb86dfb71eb9355deef4cce062ca097c53a90a"
KEYTOOL="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}/bin/keytool"

parmak_izi() {
  "$KEYTOOL" -list -v -keystore "$1" -storepass android 2>/dev/null \
    | grep -m1 'SHA256:' | awk '{print $2}' | tr -d ':' | tr 'A-F' 'a-f'
}

if [ "$(parmak_izi "$KEYSTORE")" != "$BEKLENEN_IMZA" ]; then
  echo "HATA: $KEYSTORE yayınları imzalayan anahtar değil." >&2
  exit 1
fi

echo "Yedek için bir şifre belirle (iki kez sorulacak):"
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in "$KEYSTORE" -out "$OUT"

# Yedeğin gerçekten açıldığını ve AYNI anahtarı verdiğini doğrula.
TMP=$(mktemp -d)
echo "Doğrulama: aynı şifreyi bir kez daha gir:"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in "$OUT" -out "$TMP/k"
if [ "$(parmak_izi "$TMP/k")" = "$BEKLENEN_IMZA" ]; then
  rm -rf "$TMP"
  echo "Tamam: $OUT"
  echo "Bu dosyayı Drive'a ya da USB belleğe koy; şifreyi bir yere not et."
else
  rm -rf "$TMP" "$OUT"
  echo "HATA: yedek doğrulanamadı, silindi. Yeniden dene." >&2
  exit 1
fi
