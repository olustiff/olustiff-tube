#!/bin/zsh
# Telefondaki kalıcı oynatma günlüğünü bilgisayara çeker ve gösterir.
#
# Günlüğü uygulama yazıyor (bkz. diag/Tanilama.kt): takılmalar ve süreleri,
# yükleme/oynatıcı hataları, ağ beklemeleri, o anki ağ türü. Son 7 gün,
# en fazla ~600 KB. Telefon USB ile takılı ve hata ayıklama açık olmalı.
#
# Kullanım: tool/tanilama_al.sh [cihaz-seri-no]
set -e
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
CIHAZ=${1:+-s $1}
KAYNAK=/sdcard/Android/data/com.olustiff.app/files/tanilama
HEDEF="${TMPDIR:-/tmp}/olustiff-tanilama-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$HEDEF"
for f in olaylar.1.log olaylar.log; do
  ${=ADB} ${=CIHAZ} pull "$KAYNAK/$f" "$HEDEF/$f" > /dev/null 2>&1 || true
done
if [ -z "$(ls "$HEDEF" 2>/dev/null)" ]; then
  echo "Günlük bulunamadı (uygulama hiç açılmamış ya da telefon bağlı değil)." >&2
  exit 1
fi
cat "$HEDEF"/olaylar.1.log "$HEDEF"/olaylar.log 2>/dev/null > "$HEDEF/hepsi.log" || true  # eski dosya yoksa da sürsün
echo "Kaydedildi: $HEDEF/hepsi.log ($(wc -l < "$HEDEF/hepsi.log" | tr -d ' ') satır)"
echo
echo "== özet =="
echo "beklemeler (3 sn+): $(grep -c 'Bekleme ' "$HEDEF/hepsi.log" || true)"
echo "ağ beklemeleri    : $(grep -c 'ağ bekleniyor' "$HEDEF/hepsi.log" || true)"
echo "takılma bekçisi   : $(grep -c 'Takılma:' "$HEDEF/hepsi.log" || true)"
echo "oynatıcı hataları : $(grep -c 'Oynatıcı hatası' "$HEDEF/hepsi.log" || true)"
echo "açılamayan parça  : $(grep -c 'Parça açılamadı' "$HEDEF/hepsi.log" || true)"
echo
echo "== son 30 olay =="
tail -30 "$HEDEF/hepsi.log"
