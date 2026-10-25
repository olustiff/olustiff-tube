#!/bin/zsh
# Telefon Mac'e MEDYA AKTARIMI (dosya aktarımı) modunda bağlıyken ekranının
# kapanıp kilitlenmesini engeller (ya da bunu kaldırır).
#
# ## Neden Android'in "şarjdayken uyanık kal" ayarı değil
#
# O ayar USB modunu tanımıyor; üstelik bu telefon Mac'in kablosunu "şarj
# cihazı" (AC) olarak görüyor. Ayar açık kalınca duvar ve araba şarjında da
# ekran kapanmıyordu. Telefonun içinde çalışan bir bekçi de denendi: USB modu
# değişince Android adb bağlantısını yeniden başlatıyor ve bekçiyi öldürüyor.
#
# ## Nasıl
#
# Telefondaki ayar KAPALI kalıyor. Mac'te bir launchd görevi 8 saniyede bir
# bakıyor: telefon bağlı, MTP modunda ve ekranı açıksa ona zararsız bir tuş
# (KEYCODE_UNKNOWN, hiçbir uygulamada karşılığı yok) gönderiyor; bu, ekranın
# kapanma süresini (telefonda 15 sn) sıfırlıyor. Kablo çıkınca ya da "sadece
# şarj"a geçince sinyal gelmiyor, telefon normal davranıyor. Ekran kapalıysa
# (ör. güç tuşuyla kapatıldıysa) dokunulmuyor — telefonu uyandırmıyor.
#
# Betik `~/Library/Application Support` altına kopyalanıyor: launchd
# `~/Desktop`'u okuyamıyor (bkz. otomatik_kontrol_kur.sh).
#
# Kullanım:
#   tool/ekran_bekci.sh           # kurar
#   tool/ekran_bekci.sh --kaldir
set -e

ETIKET="com.olustiff.ekran-uyanik"
PLIST="$HOME/Library/LaunchAgents/$ETIKET.plist"
EV="$HOME/Library/Application Support/olustiff"
BEKCI="$EV/ekran_uyanik.sh"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

if [ "$1" = "--kaldir" ]; then
  launchctl bootout "gui/$(id -u)/$ETIKET" 2>/dev/null || true
  rm -f "$PLIST" "$BEKCI"
  echo "Ekran bekçisi kaldırıldı."
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$EV"

cat > "$BEKCI" <<BEKCISON
#!/bin/zsh
# tool/ekran_bekci.sh tarafından üretiliyor; elle düzenlemeyin.
# Bağlı her telefon için: MTP modunda ve ekran açıksa kapanma süresini sıfırla.
ADB="$ADB"
[ -x "\$ADB" ] || exit 0
for seri in \$("\$ADB" devices | awk 'NR>1 && \$2=="device" {print \$1}'); do
  "\$ADB" -s "\$seri" shell 'dumpsys usb | grep -q "current_functions=.*MTP" &&
    dumpsys power | grep -q "mWakefulness=Awake" &&
    input keyevent KEYCODE_UNKNOWN' > /dev/null 2>&1
done
exit 0
BEKCISON
chmod +x "$BEKCI"

cat > "$PLIST" <<PLISTSON
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ETIKET</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$BEKCI</string></array>
  <key>StartInterval</key><integer>8</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PLISTSON

launchctl bootout "gui/$(id -u)/$ETIKET" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# Telefondaki "şarjdayken uyanık kal" ayarı artık gerekmiyor; açık kalırsa
# duvar/araba şarjında da ekran kapanmazdı.
for seri in $("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}'); do
  "$ADB" -s "$seri" shell settings put global stay_on_while_plugged_in 0
done
echo "Ekran bekçisi kuruldu: telefon medya aktarımında bağlıyken ekran kapanmaz."
