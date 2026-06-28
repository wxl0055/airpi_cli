#!/usr/bin/env bash
set -euo pipefail

echo "Apply Airpi AP3000M MMC EEPROM WiFi fix v2"

WRT="${GITHUB_WORKSPACE:-$(pwd)}/wrt"
[ -d "$WRT" ] || WRT="/mnt/build_wrt"
[ -d "$WRT" ] || { echo "ERROR: OpenWrt source root not found"; exit 1; }

cd "$WRT"

DTS=""
for f in \
  target/linux/mediatek/dts/mt7981-airpi-ap3000m.dts \
  target/linux/mediatek/dts/mt7981b-Airpi-emmc16G.dts \
  target/linux/mediatek/dts/mt7981b-airpi-ap3000m.dts
do
  [ -f "$f" ] && DTS="$f" && break
done

WIFIMAC="target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac"

[ -n "$DTS" ] && [ -f "$DTS" ] || { echo "ERROR: missing Airpi DTS"; exit 1; }
[ -f "$WIFIMAC" ] || { echo "ERROR: missing $WIFIMAC"; exit 1; }

echo "DTS=$DTS"
echo "WIFIMAC=$WIFIMAC"

if ! grep -q 'eeprom_factory_0:' "$DTS"; then
  echo "ERROR: current Airpi DTS has no eeprom_factory_0"
  grep -nEi 'factory|eeprom|nvmem|wifi' "$DTS" || true
  exit 1
fi

python3 - "$DTS" "$WIFIMAC" <<'PY'
from pathlib import Path
import re
import sys

dts = Path(sys.argv[1])
wifimac = Path(sys.argv[2])

def replace_dts_node(text, node_name, new_block):
    pos = text.find(node_name)
    if pos < 0:
        raise SystemExit(f"ERROR: {node_name} not found")

    brace = text.find("{", pos)
    if brace < 0:
        raise SystemExit(f"ERROR: {node_name} has no opening brace")

    depth = 0
    end = None

    for i in range(brace, len(text)):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                j = i + 1
                while j < len(text) and text[j].isspace():
                    j += 1
                if j < len(text) and text[j] == ";":
                    end = j + 1
                    break

    if end is None:
        raise SystemExit(f"ERROR: cannot locate end of {node_name}")

    return text[:pos] + new_block + text[end:]

# 1. DTS: remove static mediatek,eeprom-data and bind real MMC factory EEPROM
s = dts.read_text()

wifi_block = '''&wifi {
    /*
     * Airpi AP3000M: use real EEPROM from eMMC factory nvmem cell.
     * Static mediatek,eeprom-data is removed to avoid wrong 2.4G/5G MAC.
     */
    nvmem-cells = <&eeprom_factory_0>;
    nvmem-cell-names = "eeprom";
    status = "okay";
};
'''

s = replace_dts_node(s, "&wifi", wifi_block)

m = re.search(r'&wifi\s*\{.*?\n\};', s, re.S)
if not m:
    raise SystemExit("ERROR: &wifi block missing after patch")
if "mediatek,eeprom-data" in m.group(0):
    raise SystemExit("ERROR: mediatek,eeprom-data still active in &wifi")

dts.write_text(s)

# 2. WiFi MAC hotplug: read 2.4G/5G MAC from MMC factory offsets
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
    s = pat.sub("\n" + block, s, count=1)
else:
    m = re.search(r'\n[ \t]*[a-z0-9_-]+,[a-z0-9_.-]+\)\n', s)
    if not m:
        raise SystemExit("ERROR: cannot find insert point in 11_fix_wifi_mac")
    s = s[:m.start()] + "\n" + block + "\n" + s[m.start():]

wifimac.write_text(s)
PY

echo
echo "== Verify DTS =="
grep -nA10 -B3 'nvmem-cells\|nvmem-cell-names\|mediatek,eeprom-data\|&wifi' "$DTS" || true

echo
echo "== Verify WiFi MAC =="
grep -nA20 -B3 'airpi,ap3000m)' "$WIFIMAC" || true

echo
echo "Airpi AP3000M MMC EEPROM WiFi fix v2 applied."
