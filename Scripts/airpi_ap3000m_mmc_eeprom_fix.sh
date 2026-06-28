#!/usr/bin/env bash
set -euo pipefail

echo "Apply Airpi AP3000M MMC EEPROM WiFi fix"

WRT="${GITHUB_WORKSPACE:-$(pwd)}/wrt"
[ -d "$WRT" ] || WRT="/mnt/build_wrt"

if [ ! -d "$WRT" ]; then
  echo "ERROR: OpenWrt source root not found"
  echo "GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-}"
  ls -la "${GITHUB_WORKSPACE:-.}" || true
  ls -la /mnt || true
  exit 1
fi

cd "$WRT"

DTS=""
for f in \
  target/linux/mediatek/dts/mt7981-airpi-ap3000m.dts \
  target/linux/mediatek/dts/mt7981b-airpi-ap3000m.dts \
  target/linux/mediatek/dts/mt7981b-Airpi-emmc16G.dts
do
  [ -f "$f" ] && DTS="$f" && break
done

if [ -z "$DTS" ]; then
  DTS="$(find target/linux/mediatek/dts -type f 2>/dev/null | grep -Ei 'airpi.*ap3000m|ap3000m.*airpi|Airpi.*emmc' | head -n1 || true)"
fi

WIFIMAC="target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac"

[ -n "$DTS" ] && [ -f "$DTS" ] || { echo "ERROR: missing Airpi AP3000M DTS"; exit 1; }
[ -f "$WIFIMAC" ] || { echo "ERROR: missing $WIFIMAC"; exit 1; }

echo "DTS=$DTS"
echo "WIFIMAC=$WIFIMAC"

if ! grep -R "eeprom_factory_0:" target/linux/mediatek/dts target/linux/mediatek/filogic/base-files 2>/dev/null; then
  echo "ERROR: eeprom_factory_0 not found. Stop to avoid wrong EEPROM binding."
  echo "Hint: please audit DTS nvmem/factory label first."
  grep -RniE 'factory|eeprom|nvmem' target/linux/mediatek/dts 2>/dev/null | head -120 || true
  exit 1
fi

python3 - "$DTS" "$WIFIMAC" <<'PY'
from pathlib import Path
import re
import sys

dts = Path(sys.argv[1])
wifimac = Path(sys.argv[2])

# 1. DTS: force WiFi EEPROM from MMC factory nvmem cell
s = dts.read_text()

wifi_block = '''&wifi {
    /*
     * Airpi AP3000M must use real EEPROM from eMMC factory area.
     * Do not use static mediatek,eeprom-data here.
     */
    nvmem-cells = <&eeprom_factory_0>;
    nvmem-cell-names = "eeprom";
    status = "okay";
};
'''

s2, n = re.subn(r'&wifi\s*\{.*?\n\};', wifi_block, s, flags=re.S)

if n != 1:
    raise SystemExit(f"ERROR: expected exactly one &wifi block, replaced {n}")

m = re.search(r'&wifi\s*\{.*?\n\};', s2, flags=re.S)
if not m:
    raise SystemExit("ERROR: &wifi block missing after patch")

if "mediatek,eeprom-data" in m.group(0):
    raise SystemExit("ERROR: active mediatek,eeprom-data still exists in &wifi block")

dts.write_text(s2)

# 2. ieee80211 hotplug: WiFi MAC from MMC factory offsets
s = wifimac.read_text()

block = '''    airpi,ap3000m)
        addr0="$(mmc_get_mac_binary factory 0x04 2>/dev/null)"
        addr1="$(mmc_get_mac_binary factory 0x0a 2>/dev/null)"
        case "$addr0" in
            ""|00:00:00:*|02:00:00:10:00:*|ff:ff:ff:ff:ff:ff)
                addr0=
                ;;
        esac
        case "$addr1" in
            ""|00:00:00:*|02:00:00:10:00:*|ff:ff:ff:ff:ff:ff)
                addr1=
                ;;
        esac
        [ "$PHYNBR" = "0" ] && [ -n "$addr0" ] && echo "$addr0" > /sys${DEVPATH}/macaddress
        [ "$PHYNBR" = "1" ] && [ -n "$addr1" ] && echo "$addr1" > /sys${DEVPATH}/macaddress
        ;;'''

pat = re.compile(r'\n[ \t]*airpi,ap3000m\)\n.*?\n[ \t]*;;', re.S)

if pat.search(s):
    s2 = pat.sub("\n" + block, s, count=1)
else:
    m = re.search(r'\n[ \t]*[a-z0-9_-]+,[a-z0-9_.-]+\)\n', s)
    if not m:
        raise SystemExit("ERROR: cannot find insert point in 11_fix_wifi_mac")
    s2 = s[:m.start()] + "\n" + block + "\n" + s[m.start():]

wifimac.write_text(s2)
PY

echo
echo "== Verify DTS WiFi EEPROM =="
grep -nA10 -B3 'nvmem-cells\|nvmem-cell-names\|mediatek,eeprom-data\|&wifi' "$DTS" || true

echo
echo "== Verify WiFi MAC hotplug =="
grep -nA20 -B3 'airpi,ap3000m)' "$WIFIMAC" || true

echo
echo "Airpi AP3000M MMC EEPROM WiFi fix applied."
