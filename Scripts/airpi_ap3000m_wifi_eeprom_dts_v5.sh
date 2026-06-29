#!/usr/bin/env bash
set -euo pipefail

echo "Apply Airpi AP3000M WiFi EEPROM DTS fix v5"

WRT="${GITHUB_WORKSPACE:-$(pwd)}/wrt"
[ -d "$WRT" ] || WRT="/mnt/build_wrt"
[ -d "$WRT" ] || {
  echo "ERROR: OpenWrt source root not found"
  echo "GITHUB_WORKSPACE=${GITHUB_WORKSPACE:-}"
  ls -la "${GITHUB_WORKSPACE:-.}" || true
  ls -la /mnt || true
  exit 1
}

cd "$WRT"

echo
echo "== Source root =="
pwd

echo
echo "== Find Airpi/AP3000M DTS candidates =="
mapfile -t DTS_FILES < <(
  find target/linux/mediatek/dts -type f \( -name '*.dts' -o -name '*.dtsi' -o -name '*.dtso' \) 2>/dev/null |
  while read -r f; do
    if grep -qiE 'airpi,ap3000m|Airpi AP3000M|Airpi EMMC|Airpi,emmc-16g|ap3000m' "$f"; then
      echo "$f"
    fi
  done | sort -u
)

if [ "${#DTS_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no Airpi/AP3000M DTS found"
  exit 1
fi

printf '%s\n' "${DTS_FILES[@]}"

echo
echo "== Patch Airpi/AP3000M DTS files =="
python3 - "${DTS_FILES[@]}" <<'PY'
from pathlib import Path
import re
import sys

files = [Path(x) for x in sys.argv[1:]]

def find_node_end(text, pos):
    brace = text.find("{", pos)
    if brace < 0:
        return None
    depth = 0
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
                    return j + 1
    return None

def replace_wifi_node(text):
    pos = text.find("&wifi")
    if pos < 0:
        return text, False

    end = find_node_end(text, pos)
    if end is None:
        raise SystemExit("ERROR: cannot locate end of &wifi node")

    block = '''&wifi {
    /*
     * Airpi AP3000M: use EEPROM from eMMC factory NVMEM.
     * Do not embed static EEPROM data in DTB.
     */
    nvmem-cells = <&eeprom_factory_0>;
    nvmem-cell-names = "eeprom";
    status = "okay";
};
'''
    return text[:pos] + block + text[end:], True

def has_active_eeprom_data_in_wifi(text):
    m = re.search(r'&wifi\s*\{.*?\n\};', text, re.S)
    if not m:
        return False
    block = m.group(0)
    block = re.sub(r'/\*.*?\*/', '', block, flags=re.S)
    block = re.sub(r'//.*', '', block)
    return "mediatek,eeprom-data" in block

patched = []
skipped = []

for p in files:
    s = p.read_text()

    # 只处理包含 eeprom_factory_0 的 DTS，避免误改不完整旧文件
    if "eeprom_factory_0:" not in s:
        skipped.append((str(p), "no eeprom_factory_0"))
        continue

    s2, changed = replace_wifi_node(s)
    if changed:
        if has_active_eeprom_data_in_wifi(s2):
            raise SystemExit(f"ERROR: active mediatek,eeprom-data remains in {p}")
        p.write_text(s2)
        patched.append(str(p))
    else:
        skipped.append((str(p), "no &wifi node"))

print("PATCHED:")
for x in patched:
    print(x)

print("SKIPPED:")
for x, reason in skipped:
    print(f"{x} [{reason}]")

if not patched:
    raise SystemExit("ERROR: no DTS patched")
PY

echo
echo "== Verify patched DTS source =="
BAD=0

for f in "${DTS_FILES[@]}"; do
  echo
  echo "---- $f ----"
  grep -nA10 -B3 'eeprom_factory_0\|nvmem-cells\|nvmem-cell-names\|mediatek,eeprom-data\|&wifi' "$f" || true

  if grep -q 'eeprom_factory_0:' "$f" && grep -q '&wifi' "$f"; then
    python3 - "$f" <<'PY' || BAD=1
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
m = re.search(r'&wifi\s*\{.*?\n\};', s, re.S)
if not m:
    raise SystemExit(0)
block = m.group(0)
clean = re.sub(r'/\*.*?\*/', '', block, flags=re.S)
clean = re.sub(r'//.*', '', clean)
if "mediatek,eeprom-data" in clean:
    raise SystemExit(f"BAD: active mediatek,eeprom-data in {p}")
if "nvmem-cells = <&eeprom_factory_0>;" not in clean:
    raise SystemExit(f"BAD: no eeprom_factory_0 nvmem-cells in {p}")
if 'nvmem-cell-names = "eeprom";' not in clean:
    raise SystemExit(f"BAD: no eeprom cell name in {p}")
print(f"OK: {p}")
PY
  fi
done

[ "$BAD" = "0" ] || {
  echo "ERROR: DTS verification failed"
  exit 1
}

echo
echo "== Optional: patch 11_fix_wifi_mac for factory 0x04/0x0a evidence =="
WIFIMAC="target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac"

if [ -f "$WIFIMAC" ]; then
  python3 - "$WIFIMAC" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

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

p.write_text(s)
PY

  grep -nA20 -B3 'airpi,ap3000m)' "$WIFIMAC" || true
else
  echo "WARN: $WIFIMAC not found, skipped"
fi

echo
echo "== Add DTB verification helper into source tree =="
mkdir -p files/usr/sbin

cat > files/usr/sbin/ap3000m-dtb-eeprom-check <<'EOS'
#!/bin/sh

[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "airpi,ap3000m" ] || exit 0

WIFI_NODE="/sys/firmware/devicetree/base/soc/wifi@18000000"

echo "board=$(cat /tmp/sysinfo/board_name 2>/dev/null)"

if [ -e "$WIFI_NODE/mediatek,eeprom-data" ]; then
    echo "BAD: runtime DTB still has mediatek,eeprom-data"
    wc -c "$WIFI_NODE/mediatek,eeprom-data" 2>/dev/null || true
else
    echo "OK: runtime DTB has no mediatek,eeprom-data"
fi

echo "runtime nvmem/eeprom nodes:"
find /sys/firmware/devicetree/base -name '*eeprom*' -o -name '*nvmem*' 2>/dev/null | head -80

echo "factory MAC:"
. /lib/functions/system.sh 2>/dev/null
echo "factory 0x04=$(mmc_get_mac_binary factory 0x04 2>/dev/null)"
echo "factory 0x0a=$(mmc_get_mac_binary factory 0x0a 2>/dev/null)"

echo "wifi if MAC:"
for i in ra0 rax0; do
    [ -e "/sys/class/net/$i/address" ] && echo "$i=$(cat /sys/class/net/$i/address)"
done
EOS

chmod +x files/usr/sbin/ap3000m-dtb-eeprom-check

echo
echo "== Final source verification summary =="
grep -RniE 'airpi,ap3000m|Airpi AP3000M|nvmem-cells = <&eeprom_factory_0>|nvmem-cell-names = "eeprom"|mediatek,eeprom-data' \
  target/linux/mediatek/dts/mt7981*airpi* target/linux/mediatek/dts/mt7981*Airpi* 2>/dev/null || true

echo
echo "Airpi AP3000M WiFi EEPROM DTS fix v5 applied."
